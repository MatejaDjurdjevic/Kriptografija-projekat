const { expect } = require("chai");
const { ethers } = require("hardhat");
const { anyValue } = require("@nomicfoundation/hardhat-chai-matchers/withArgs");

// Pomocna konstanta koja odgovara enum State u ugovoru
const State = {
  Created: 0,
  Funded: 1,
  Completed: 2,
  Disputed: 3,
  Resolved: 4,
};

describe("ConditionalEscrow", function () {
  let escrow;
  let buyer, seller, arbiter, stranger;
  const depositAmount = ethers.parseEther("1.0");

  beforeEach(async function () {
    [buyer, seller, arbiter, stranger] = await ethers.getSigners();

    const ConditionalEscrow = await ethers.getContractFactory("ConditionalEscrow");
    escrow = await ConditionalEscrow.deploy();
    await escrow.waitForDeployment();
  });

  // ------------------------------------------------------------------
  // Kreiranje i finansiranje escrow-a
  // ------------------------------------------------------------------
  describe("Kreiranje escrow-a", function () {
    it("uspesno kreira i finansira escrow, emituje evente i cuva ispravno stanje", async function () {
      const tx = await escrow
        .connect(buyer)
        .createEscrow(seller.address, arbiter.address, { value: depositAmount });

      await expect(tx)
        .to.emit(escrow, "EscrowCreated")
        .withArgs(0, buyer.address, seller.address, arbiter.address, depositAmount, anyValue);

      await expect(tx).to.emit(escrow, "EscrowFunded");

      const data = await escrow.getEscrow(0);
      expect(data.buyer).to.equal(buyer.address);
      expect(data.seller).to.equal(seller.address);
      expect(data.arbiter).to.equal(arbiter.address);
      expect(data.amount).to.equal(depositAmount);
      expect(data.state).to.equal(State.Funded);

      expect(await escrow.escrowCount()).to.equal(1);
    });

    it("odbija kreiranje sa iznosom 0", async function () {
      await expect(
        escrow.connect(buyer).createEscrow(seller.address, arbiter.address, { value: 0 })
      ).to.be.revertedWith("ConditionalEscrow: iznos mora biti > 0");
    });

    it("odbija kreiranje ako je prodavac ujedno i kupac", async function () {
      await expect(
        escrow
          .connect(buyer)
          .createEscrow(buyer.address, arbiter.address, { value: depositAmount })
      ).to.be.revertedWith("ConditionalEscrow: prodavac ne moze biti kupac");
    });

    it("odbija kreiranje ako arbitar nije neutralan (arbitar == kupac)", async function () {
      await expect(
        escrow
          .connect(buyer)
          .createEscrow(seller.address, buyer.address, { value: depositAmount })
      ).to.be.revertedWith("ConditionalEscrow: arbitar mora biti neutralna strana");
    });

    it("odbija kreiranje ako arbitar nije neutralan (arbitar == prodavac)", async function () {
      await expect(
        escrow
          .connect(buyer)
          .createEscrow(seller.address, seller.address, { value: depositAmount })
      ).to.be.revertedWith("ConditionalEscrow: arbitar mora biti neutralna strana");
    });

    it("odbija kreiranje sa nultom adresom prodavca ili arbitra", async function () {
      await expect(
        escrow
          .connect(buyer)
          .createEscrow(ethers.ZeroAddress, arbiter.address, { value: depositAmount })
      ).to.be.revertedWith("ConditionalEscrow: nevazeca adresa prodavca");

      await expect(
        escrow
          .connect(buyer)
          .createEscrow(seller.address, ethers.ZeroAddress, { value: depositAmount })
      ).to.be.revertedWith("ConditionalEscrow: nevazeca adresa arbitra");
    });

    it("direktno slanje ETH-a na ugovor (mimo createEscrow) se odbija", async function () {
      await expect(
        buyer.sendTransaction({ to: await escrow.getAddress(), value: depositAmount })
      ).to.be.revertedWith("ConditionalEscrow: koristite createEscrow()");
    });
  });

  // ------------------------------------------------------------------
  // Oslobadjanje sredstava prodavcu (potvrda kupca)
  // ------------------------------------------------------------------
  describe("confirmReceipt - oslobadjanje sredstava prodavcu", function () {
    beforeEach(async function () {
      await escrow
        .connect(buyer)
        .createEscrow(seller.address, arbiter.address, { value: depositAmount });
    });

    it("kupac moze da potvrdi prijem i prodavac dobija sredstva", async function () {
      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);

      await expect(escrow.connect(buyer).confirmReceipt(0))
        .to.emit(escrow, "FundsReleased")
        .withArgs(0, seller.address, depositAmount, anyValue);

      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      expect(sellerBalanceAfter - sellerBalanceBefore).to.equal(depositAmount);

      const data = await escrow.getEscrow(0);
      expect(data.state).to.equal(State.Completed);
      expect(data.amount).to.equal(0);
    });

    it("sprecava dvostruko oslobadjanje istih sredstava", async function () {
      await escrow.connect(buyer).confirmReceipt(0);
      await expect(escrow.connect(buyer).confirmReceipt(0)).to.be.revertedWith(
        "ConditionalEscrow: nevazece stanje"
      );
    });

    it("samo kupac moze pozvati confirmReceipt (kontrola pristupa)", async function () {
      await expect(escrow.connect(seller).confirmReceipt(0)).to.be.revertedWith(
        "ConditionalEscrow: samo kupac"
      );
      await expect(escrow.connect(stranger).confirmReceipt(0)).to.be.revertedWith(
        "ConditionalEscrow: samo kupac"
      );
      await expect(escrow.connect(arbiter).confirmReceipt(0)).to.be.revertedWith(
        "ConditionalEscrow: samo kupac"
      );
    });

    it("ne moze potvrditi prijem za nepostojeci escrow", async function () {
      await expect(escrow.connect(buyer).confirmReceipt(99)).to.be.revertedWith(
        "ConditionalEscrow: escrow ne postoji"
      );
    });
  });

  // ------------------------------------------------------------------
  // Dobrovoljni povracaj kupcu od strane prodavca
  // ------------------------------------------------------------------
  describe("refundBuyer - povracaj kupcu", function () {
    beforeEach(async function () {
      await escrow
        .connect(buyer)
        .createEscrow(seller.address, arbiter.address, { value: depositAmount });
    });

    it("prodavac moze dobrovoljno da vrati sredstva kupcu", async function () {
      const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address);

      await expect(escrow.connect(seller).refundBuyer(0))
        .to.emit(escrow, "FundsRefunded")
        .withArgs(0, buyer.address, depositAmount, anyValue);

      const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);
      expect(buyerBalanceAfter - buyerBalanceBefore).to.equal(depositAmount);

      const data = await escrow.getEscrow(0);
      expect(data.state).to.equal(State.Completed);
    });

    it("samo prodavac moze pozvati refundBuyer", async function () {
      await expect(escrow.connect(buyer).refundBuyer(0)).to.be.revertedWith(
        "ConditionalEscrow: samo prodavac"
      );
      await expect(escrow.connect(arbiter).refundBuyer(0)).to.be.revertedWith(
        "ConditionalEscrow: samo prodavac"
      );
    });

    it("ne moze vratiti sredstva ako escrow nije u stanju Funded", async function () {
      await escrow.connect(seller).refundBuyer(0);
      await expect(escrow.connect(seller).refundBuyer(0)).to.be.revertedWith(
        "ConditionalEscrow: nevazece stanje"
      );
    });
  });

  // ------------------------------------------------------------------
  // Pokretanje i razresenje spora
  // ------------------------------------------------------------------
  describe("raiseDispute i resolveDispute - arbitraza", function () {
    beforeEach(async function () {
      await escrow
        .connect(buyer)
        .createEscrow(seller.address, arbiter.address, { value: depositAmount });
    });

    it("kupac moze da pokrene spor", async function () {
      await expect(escrow.connect(buyer).raiseDispute(0))
        .to.emit(escrow, "DisputeRaised")
        .withArgs(0, buyer.address, anyValue);

      const data = await escrow.getEscrow(0);
      expect(data.state).to.equal(State.Disputed);
    });

    it("prodavac moze da pokrene spor", async function () {
      await expect(escrow.connect(seller).raiseDispute(0))
        .to.emit(escrow, "DisputeRaised")
        .withArgs(0, seller.address, anyValue);
    });

    it("trece lice ne moze da pokrene spor", async function () {
      await expect(escrow.connect(stranger).raiseDispute(0)).to.be.revertedWith(
        "ConditionalEscrow: samo ucesnik posla"
      );
    });

    it("arbitar razresava spor u korist prodavca", async function () {
      await escrow.connect(buyer).raiseDispute(0);
      const sellerBalanceBefore = await ethers.provider.getBalance(seller.address);

      await expect(escrow.connect(arbiter).resolveDispute(0, seller.address))
        .to.emit(escrow, "DisputeResolved")
        .withArgs(0, seller.address, depositAmount, anyValue);

      const sellerBalanceAfter = await ethers.provider.getBalance(seller.address);
      expect(sellerBalanceAfter - sellerBalanceBefore).to.equal(depositAmount);

      const data = await escrow.getEscrow(0);
      expect(data.state).to.equal(State.Resolved);
    });

    it("arbitar razresava spor u korist kupca", async function () {
      await escrow.connect(seller).raiseDispute(0);
      const buyerBalanceBefore = await ethers.provider.getBalance(buyer.address);

      await expect(escrow.connect(arbiter).resolveDispute(0, buyer.address))
        .to.emit(escrow, "DisputeResolved")
        .withArgs(0, buyer.address, depositAmount, anyValue);

      const buyerBalanceAfter = await ethers.provider.getBalance(buyer.address);
      expect(buyerBalanceAfter - buyerBalanceBefore).to.equal(depositAmount);
    });

    it("samo arbitar moze razresiti spor (kontrola pristupa)", async function () {
      await escrow.connect(buyer).raiseDispute(0);
      await expect(
        escrow.connect(buyer).resolveDispute(0, buyer.address)
      ).to.be.revertedWith("ConditionalEscrow: samo arbitar");
      await expect(
        escrow.connect(seller).resolveDispute(0, seller.address)
      ).to.be.revertedWith("ConditionalEscrow: samo arbitar");
    });

    it("ne moze razresiti spor koji nije pokrenut", async function () {
      await expect(
        escrow.connect(arbiter).resolveDispute(0, buyer.address)
      ).to.be.revertedWith("ConditionalEscrow: spor nije aktivan");
    });

    it("arbitar ne moze dodeliti sredstva trecem licu (zaobilazenje pravila)", async function () {
      await escrow.connect(buyer).raiseDispute(0);
      await expect(
        escrow.connect(arbiter).resolveDispute(0, stranger.address)
      ).to.be.revertedWith("ConditionalEscrow: pobednik mora biti kupac ili prodavac");
    });

    it("sprecava dvostruko razresenje istog spora", async function () {
      await escrow.connect(buyer).raiseDispute(0);
      await escrow.connect(arbiter).resolveDispute(0, seller.address);
      await expect(
        escrow.connect(arbiter).resolveDispute(0, buyer.address)
      ).to.be.revertedWith("ConditionalEscrow: spor nije aktivan");
    });

    it("ne moze pokrenuti spor koji vec traje", async function () {
      await escrow.connect(buyer).raiseDispute(0);
      await expect(escrow.connect(seller).raiseDispute(0)).to.be.revertedWith(
        "ConditionalEscrow: nevazece stanje"
      );
    });
  });

  // ------------------------------------------------------------------
  // Visestruki nezavisni escrow poslovi
  // ------------------------------------------------------------------
  describe("Vise nezavisnih escrow poslova", function () {
    it("stanja razlicitih escrow-ova se ne mesaju medjusobno", async function () {
      await escrow
        .connect(buyer)
        .createEscrow(seller.address, arbiter.address, { value: depositAmount });
      await escrow
        .connect(buyer)
        .createEscrow(seller.address, arbiter.address, { value: ethers.parseEther("2.0") });

      await escrow.connect(buyer).confirmReceipt(0);

      const data0 = await escrow.getEscrow(0);
      const data1 = await escrow.getEscrow(1);

      expect(data0.state).to.equal(State.Completed);
      expect(data1.state).to.equal(State.Funded);
      expect(data1.amount).to.equal(ethers.parseEther("2.0"));
    });
  });
});

