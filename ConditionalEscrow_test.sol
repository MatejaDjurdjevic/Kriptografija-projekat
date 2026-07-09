pragma solidity ^0.8.24;


import "remix_tests.sol";
import "remix_accounts.sol";
import "../contracts/Escrow.sol";


contract EscrowActor {
    ConditionalEscrow public target;

    constructor(ConditionalEscrow _target) {
        target = _target;
    }

    // Omogucava da se ugovor-glumac finansira testnim ETH-om
    receive() external payable {}

    function createEscrow(address payable seller, address arbiter, uint256 value)
        public
        returns (uint256)
    {
        return target.createEscrow{value: value}(seller, arbiter);
    }

    function confirmReceipt(uint256 id) public {
        target.confirmReceipt(id);
    }

    function refundBuyer(uint256 id) public {
        target.refundBuyer(id);
    }

    function raiseDispute(uint256 id) public {
        target.raiseDispute(id);
    }

    function resolveDispute(uint256 id, address payable winner) public {
        target.resolveDispute(id, winner);
    }

    // Koristi se da se posalje "gola" ETH transakcija direktno na escrow
    // (test da receive() u ugovoru odbija takve uplate)
    function sendRawTo(address payable to, uint256 value) public {
        (bool ok, ) = to.call{value: value}("");
        require(ok, "raw send failed");
    }
}

/// Glavni test ugovor
contract ConditionalEscrow_test {
    ConditionalEscrow escrow;

    EscrowActor buyerActor;
    EscrowActor sellerActor;
    EscrowActor arbiterActor;
    EscrowActor strangerActor;

    uint256 constant DEPOSIT = 1 ether;

    /// beforeAll se izvrsava jednom, pre svih test funkcija
    function beforeAll() public {
        escrow = new ConditionalEscrow();

        buyerActor = new EscrowActor(escrow);
        sellerActor = new EscrowActor(escrow);
        arbiterActor = new EscrowActor(escrow);
        strangerActor = new EscrowActor(escrow);
    }

    /// Snabdeva sve actor-ugovore testnim ETH-om pre pocetka testova.
    /// #value: 100000000000000000000
    function fundActors() public payable {
        Assert.ok(msg.value > 0, "test nalog mora poslati ETH ovoj funkciji");
        uint256 share = msg.value / 4;

        (bool ok1, ) = address(buyerActor).call{value: share}("");
        (bool ok2, ) = address(sellerActor).call{value: share}("");
        (bool ok3, ) = address(arbiterActor).call{value: share}("");
        (bool ok4, ) = address(strangerActor).call{value: share}("");

        Assert.ok(ok1 && ok2 && ok3 && ok4, "finansiranje actor-ugovora nije uspelo");
    }

    // 1) Kreiranje escrow-a

    function checkInitialEscrowCount() public {
        Assert.equal(escrow.escrowCount(), uint256(0), "escrowCount treba da bude 0 na pocetku");
    }

    function checkCreateEscrowSuccess() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );
        Assert.equal(id, uint256(0), "prvi escrow treba da ima id 0");

        (
            address b,
            address s,
            address a,
            uint256 amt,
            ConditionalEscrow.State st,
            ,

        ) = escrow.getEscrow(id);

        Assert.equal(b, address(buyerActor), "buyer nije ispravno sacuvan");
        Assert.equal(s, address(sellerActor), "seller nije ispravno sacuvan");
        Assert.equal(a, address(arbiterActor), "arbiter nije ispravno sacuvan");
        Assert.equal(amt, DEPOSIT, "amount nije ispravan");
        Assert.equal(uint256(st), uint256(ConditionalEscrow.State.Funded), "state treba da bude Funded");
        Assert.equal(escrow.escrowCount(), uint256(1), "escrowCount treba da bude 1 nakon kreiranja");
    }

    function checkCreateEscrowRevertsOnZeroValue() public {
        try buyerActor.createEscrow(payable(address(sellerActor)), address(arbiterActor), 0) returns (uint256) {
            Assert.ok(false, "trebalo je da baci revert za iznos 0");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: iznos mora biti > 0", "pogresna revert poruka");
        }
    }

    function checkCreateEscrowRevertsWhenSellerIsBuyer() public {
        // buyerActor pokusava da kreira escrow gde je on i kupac i prodavac
        try buyerActor.createEscrow(payable(address(buyerActor)), address(arbiterActor), DEPOSIT) returns (uint256) {
            Assert.ok(false, "trebalo je da baci revert kada je prodavac == kupac");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: prodavac ne moze biti kupac", "pogresna revert poruka");
        }
    }

    function checkCreateEscrowRevertsWhenArbiterNotNeutral() public {
        // arbitar == kupac
        try buyerActor.createEscrow(payable(address(sellerActor)), address(buyerActor), DEPOSIT) returns (uint256) {
            Assert.ok(false, "trebalo je da baci revert kada arbitar == kupac");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: arbitar mora biti neutralna strana", "pogresna revert poruka");
        }

        // arbitar == prodavac
        try buyerActor.createEscrow(payable(address(sellerActor)), address(sellerActor), DEPOSIT) returns (uint256) {
            Assert.ok(false, "trebalo je da baci revert kada arbitar == prodavac");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: arbitar mora biti neutralna strana", "pogresna revert poruka");
        }
    }

    function checkDirectSendReverts() public {
        // Direktno slanje ETH-a na escrow (mimo createEscrow) mora biti odbijeno
        try buyerActor.sendRawTo(payable(address(escrow)), 1000) {
            Assert.ok(false, "trebalo je da baci revert za direktno slanje ETH-a");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: koristite createEscrow()", "pogresna revert poruka");
        } catch (bytes memory) {
            // Ako revert stigne bez citljive poruke (npr. usled gas forwarding
            // ogranicenja), i dalje smatramo test uspesnim jer je transakcija
            // odbijena - kriticno je da uplata NIJE prosla.
            Assert.ok(true, "transakcija je odbijena (revert bez decode-ovane poruke)");
        }
    }

    // 2) confirmReceipt - oslobadjanje sredstava prodavcu
    

    function checkConfirmReceiptReleasesFunds() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );

        uint256 sellerBalanceBefore = address(sellerActor).balance;

        buyerActor.confirmReceipt(id);

        uint256 sellerBalanceAfter = address(sellerActor).balance;
        Assert.equal(
            sellerBalanceAfter - sellerBalanceBefore,
            DEPOSIT,
            "prodavac nije primio ispravan iznos"
        );

        (, , , uint256 amt, ConditionalEscrow.State st, , ) = escrow.getEscrow(id);
        Assert.equal(uint256(st), uint256(ConditionalEscrow.State.Completed), "state treba da bude Completed");
        Assert.equal(amt, uint256(0), "amount treba da bude 0 nakon oslobadjanja");
    }

    function checkConfirmReceiptPreventsDoubleRelease() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );
        buyerActor.confirmReceipt(id); // prvi (uspesan) poziv

        try buyerActor.confirmReceipt(id) {
            Assert.ok(false, "trebalo je da baci revert na drugi poziv (double-spend)");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: nevazece stanje", "pogresna revert poruka");
        }
    }

    function checkConfirmReceiptOnlyBuyerAllowed() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );

        try sellerActor.confirmReceipt(id) {
            Assert.ok(false, "prodavac ne bi smeo moci da pozove confirmReceipt");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: samo kupac", "pogresna revert poruka");
        }

        try strangerActor.confirmReceipt(id) {
            Assert.ok(false, "trece lice ne bi smelo moci da pozove confirmReceipt");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: samo kupac", "pogresna revert poruka");
        }
    }

    
    // 3) refundBuyer - dobrovoljni povracaj kupcu
    

    function checkRefundBuyerReturnsFunds() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );

        uint256 buyerBalanceBefore = address(buyerActor).balance;

        sellerActor.refundBuyer(id);

        uint256 buyerBalanceAfter = address(buyerActor).balance;
        Assert.equal(
            buyerBalanceAfter - buyerBalanceBefore,
            DEPOSIT,
            "kupac nije primio povracaj"
        );

        (, , , , ConditionalEscrow.State st, , ) = escrow.getEscrow(id);
        Assert.equal(uint256(st), uint256(ConditionalEscrow.State.Completed), "state treba da bude Completed");
    }

    function checkRefundBuyerOnlySellerAllowed() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );

        try buyerActor.refundBuyer(id) {
            Assert.ok(false, "kupac ne bi smeo moci da pozove refundBuyer");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: samo prodavac", "pogresna revert poruka");
        }
    }

    
    // 4) raiseDispute + resolveDispute - arbitraza
   

    function checkDisputeResolvedInFavorOfSeller() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );

        buyerActor.raiseDispute(id);
        (, , , , ConditionalEscrow.State stAfterDispute, , ) = escrow.getEscrow(id);
        Assert.equal(uint256(stAfterDispute), uint256(ConditionalEscrow.State.Disputed), "state treba da bude Disputed");

        uint256 sellerBalanceBefore = address(sellerActor).balance;
        arbiterActor.resolveDispute(id, payable(address(sellerActor)));
        uint256 sellerBalanceAfter = address(sellerActor).balance;

        Assert.equal(
            sellerBalanceAfter - sellerBalanceBefore,
            DEPOSIT,
            "prodavac nije primio sredstva nakon arbitraze"
        );

        (, , , , ConditionalEscrow.State stFinal, , ) = escrow.getEscrow(id);
        Assert.equal(uint256(stFinal), uint256(ConditionalEscrow.State.Resolved), "state treba da bude Resolved");
    }

    function checkDisputeResolvedInFavorOfBuyer() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );

        sellerActor.raiseDispute(id);

        uint256 buyerBalanceBefore = address(buyerActor).balance;
        arbiterActor.resolveDispute(id, payable(address(buyerActor)));
        uint256 buyerBalanceAfter = address(buyerActor).balance;

        Assert.equal(
            buyerBalanceAfter - buyerBalanceBefore,
            DEPOSIT,
            "kupac nije primio sredstva nakon arbitraze"
        );
    }

    function checkOnlyArbiterCanResolveDispute() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );
        buyerActor.raiseDispute(id);

        try buyerActor.resolveDispute(id, payable(address(buyerActor))) {
            Assert.ok(false, "kupac ne bi smeo moci da razresi spor");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: samo arbitar", "pogresna revert poruka");
        }

        try sellerActor.resolveDispute(id, payable(address(sellerActor))) {
            Assert.ok(false, "prodavac ne bi smeo moci da razresi spor");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: samo arbitar", "pogresna revert poruka");
        }
    }

    function checkArbiterCannotAssignToThirdParty() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );
        buyerActor.raiseDispute(id);

        try arbiterActor.resolveDispute(id, payable(address(strangerActor))) {
            Assert.ok(false, "arbitar ne bi smeo moci da dodeli sredstva trecem licu");
        } catch Error(string memory reason) {
            Assert.equal(
                reason,
                "ConditionalEscrow: pobednik mora biti kupac ili prodavac",
                "pogresna revert poruka"
            );
        }
    }

    function checkCannotResolveNonDisputedEscrow() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );
        // Nije pozvano raiseDispute - escrow je i dalje u stanju Funded

        try arbiterActor.resolveDispute(id, payable(address(sellerActor))) {
            Assert.ok(false, "trebalo je da baci revert - spor nije pokrenut");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: spor nije aktivan", "pogresna revert poruka");
        }
    }

    function checkStrangerCannotRaiseDispute() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );

        try strangerActor.raiseDispute(id) {
            Assert.ok(false, "trece lice ne bi smelo moci da pokrene spor");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: samo ucesnik posla", "pogresna revert poruka");
        }
    }

    function checkCannotRaiseDisputeTwice() public {
        uint256 id = buyerActor.createEscrow(
            payable(address(sellerActor)),
            address(arbiterActor),
            DEPOSIT
        );
        buyerActor.raiseDispute(id);

        try sellerActor.raiseDispute(id) {
            Assert.ok(false, "trebalo je da baci revert - spor je vec pokrenut");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: nevazece stanje", "pogresna revert poruka");
        }
    }

    
    // 5) Nepostojeci escrow
    

    function checkNonexistentEscrowReverts() public {
        uint256 fakeId = 9999;
        try buyerActor.confirmReceipt(fakeId) {
            Assert.ok(false, "trebalo je da baci revert za nepostojeci escrow");
        } catch Error(string memory reason) {
            Assert.equal(reason, "ConditionalEscrow: escrow ne postoji", "pogresna revert poruka");
        }
    }
}
