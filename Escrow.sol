// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ConditionalEscrow - Uslovni escrow sa arbitraÅ¾om
/// @notice Omogucava kupcu da deponuje sredstva kod ugovora, koja se
///         oslobadjaju prodavcu tek nakon potvrde kupca, ili se, u slucaju
///         spora, raspodeljuju po odluci unapred dogovorenog arbitra.
/// @dev Sadrzi custom reentrancy-guard (bez OpenZeppelin zavisnosti radi
///      jednostavnosti u Remix-u), kontrolu pristupa po ulogama i
///      Checks-Effects-Interactions obrazac pri svakom transferu ETH-a.
contract ConditionalEscrow {
    // ------------------------------------------------------------------
    // Tipovi podataka
    // ------------------------------------------------------------------

    /// @notice Stanja kroz koja escrow prolazi tokom svog zivotnog ciklusa
    enum State {
        Created,   // 0 - rezervisano, u ovoj implementaciji se ne koristi
                   //     posebno jer se escrow kreira i finansira atomicno
        Funded,    // 1 - sredstva su deponovana i cekaju ishod
        Completed, // 2 - sredstva su oslobodjena (prodavcu ili nazad kupcu)
        Disputed,  // 3 - jedna od strana je pokrenula spor
        Resolved   // 4 - arbitar je razresio spor
    }

    /// @notice Podaci o pojedinacnom escrow poslu
    struct EscrowData {
        address payable buyer;
        address payable seller;
        address arbiter;
        uint256 amount;
        State state;
        uint256 createdAt;
        uint256 updatedAt;
    }

    // ------------------------------------------------------------------
    // Skladiste (storage)
    // ------------------------------------------------------------------

    /// @notice Broj kreiranih escrow-ova, ujedno sluzi kao sledeci ID
    uint256 public escrowCount;

    /// @notice Mapiranje ID -> podaci o escrow-u
    mapping(uint256 => EscrowData) private escrows;

    /// @dev Custom reentrancy-guard flag (jednostavna alternativa
    ///      OpenZeppelin ReentrancyGuard-u za Remix okruzenje)
    bool private locked;

    // ------------------------------------------------------------------
    // Eventi (revizorski trag - svi imaju timestamp radi javne provere)
    // ------------------------------------------------------------------

    event EscrowCreated(
        uint256 indexed id,
        address indexed buyer,
        address indexed seller,
        address arbiter,
        uint256 amount,
        uint256 timestamp
    );

    event EscrowFunded(uint256 indexed id, uint256 amount, uint256 timestamp);

    event FundsReleased(
        uint256 indexed id,
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );

    event FundsRefunded(
        uint256 indexed id,
        address indexed to,
        uint256 amount,
        uint256 timestamp
    );

    event DisputeRaised(
        uint256 indexed id,
        address indexed raisedBy,
        uint256 timestamp
    );

    event DisputeResolved(
        uint256 indexed id,
        address indexed winner,
        uint256 amount,
        uint256 timestamp
    );

    // ------------------------------------------------------------------
    // Modifikatori (kontrola pristupa po ulogama)
    // ------------------------------------------------------------------

    modifier nonReentrant() {
        require(!locked, "ConditionalEscrow: reentrant call");
        locked = true;
        _;
        locked = false;
    }

    modifier escrowExists(uint256 id) {
        require(id < escrowCount, "ConditionalEscrow: escrow ne postoji");
        _;
    }

    modifier onlyBuyer(uint256 id) {
        require(msg.sender == escrows[id].buyer, "ConditionalEscrow: samo kupac");
        _;
    }

    modifier onlySeller(uint256 id) {
        require(msg.sender == escrows[id].seller, "ConditionalEscrow: samo prodavac");
        _;
    }

    modifier onlyArbiter(uint256 id) {
        require(msg.sender == escrows[id].arbiter, "ConditionalEscrow: samo arbitar");
        _;
    }

    modifier onlyParticipant(uint256 id) {
        EscrowData storage e = escrows[id];
        require(
            msg.sender == e.buyer || msg.sender == e.seller,
            "ConditionalEscrow: samo ucesnik posla"
        );
        _;
    }

    // ------------------------------------------------------------------
    // Glavne funkcije
    // ------------------------------------------------------------------

    /// @notice Kupac kreira i odmah finansira novi escrow posao
    /// @param seller Adresa prodavca
    /// @param arbiter Adresa neutralnog arbitra
    /// @return id Identifikator novokreiranog escrow-a
    function createEscrow(address payable seller, address arbiter)
        external
        payable
        returns (uint256 id)
    {
        require(msg.value > 0, "ConditionalEscrow: iznos mora biti > 0");
        require(seller != address(0), "ConditionalEscrow: nevazeca adresa prodavca");
        require(arbiter != address(0), "ConditionalEscrow: nevazeca adresa arbitra");
        require(seller != msg.sender, "ConditionalEscrow: prodavac ne moze biti kupac");
        require(
            arbiter != msg.sender && arbiter != seller,
            "ConditionalEscrow: arbitar mora biti neutralna strana"
        );

        id = escrowCount;
        escrowCount = escrowCount + 1;

        escrows[id] = EscrowData({
            buyer: payable(msg.sender),
            seller: seller,
            arbiter: arbiter,
            amount: msg.value,
            state: State.Funded,
            createdAt: block.timestamp,
            updatedAt: block.timestamp
        });

        emit EscrowCreated(id, msg.sender, seller, arbiter, msg.value, block.timestamp);
        emit EscrowFunded(id, msg.value, block.timestamp);
    }

    /// @notice Kupac potvrdjuje prijem robe/usluge -> sredstva idu prodavcu
    function confirmReceipt(uint256 id)
        external
        escrowExists(id)
        onlyBuyer(id)
        nonReentrant
    {
        EscrowData storage e = escrows[id];
        require(e.state == State.Funded, "ConditionalEscrow: nevazece stanje");

        // Effects (pre interakcije - sprecava dvostruko trosenje/reentrancy)
        e.state = State.Completed;
        e.updatedAt = block.timestamp;
        uint256 amount = e.amount;
        e.amount = 0;

        // Interaction
        (bool success, ) = e.seller.call{value: amount}("");
        require(success, "ConditionalEscrow: transfer nije uspeo");

        emit FundsReleased(id, e.seller, amount, block.timestamp);
    }

    /// @notice Prodavac moze dobrovoljno da vrati sredstva kupcu (bez spora)
    function refundBuyer(uint256 id)
        external
        escrowExists(id)
        onlySeller(id)
        nonReentrant
    {
        EscrowData storage e = escrows[id];
        require(e.state == State.Funded, "ConditionalEscrow: nevazece stanje");

        e.state = State.Completed;
        e.updatedAt = block.timestamp;
        uint256 amount = e.amount;
        e.amount = 0;

        (bool success, ) = e.buyer.call{value: amount}("");
        require(success, "ConditionalEscrow: transfer nije uspeo");

        emit FundsRefunded(id, e.buyer, amount, block.timestamp);
    }

    /// @notice Kupac ili prodavac pokrece spor ako se ne slazu oko ishoda
    function raiseDispute(uint256 id)
        external
        escrowExists(id)
        onlyParticipant(id)
    {
        EscrowData storage e = escrows[id];
        require(e.state == State.Funded, "ConditionalEscrow: nevazece stanje");

        e.state = State.Disputed;
        e.updatedAt = block.timestamp;

        emit DisputeRaised(id, msg.sender, block.timestamp);
    }

    /// @notice Arbitar razresava spor u korist kupca ili prodavca
    /// @param winner Adresa kojoj se dodeljuju sredstva (mora biti kupac ili prodavac)
    function resolveDispute(uint256 id, address payable winner)
        external
        escrowExists(id)
        onlyArbiter(id)
        nonReentrant
    {
        EscrowData storage e = escrows[id];
        require(e.state == State.Disputed, "ConditionalEscrow: spor nije aktivan");
        require(
            winner == e.buyer || winner == e.seller,
            "ConditionalEscrow: pobednik mora biti kupac ili prodavac"
        );

        e.state = State.Resolved;
        e.updatedAt = block.timestamp;
        uint256 amount = e.amount;
        e.amount = 0;

        (bool success, ) = winner.call{value: amount}("");
        require(success, "ConditionalEscrow: transfer nije uspeo");

        emit DisputeResolved(id, winner, amount, block.timestamp);
    }

    // ------------------------------------------------------------------
    // View funkcije
    // ------------------------------------------------------------------

    function getEscrow(uint256 id)
        external
        view
        escrowExists(id)
        returns (
            address buyer,
            address seller,
            address arbiter,
            uint256 amount,
            State state,
            uint256 createdAt,
            uint256 updatedAt
        )
    {
        EscrowData storage e = escrows[id];
        return (e.buyer, e.seller, e.arbiter, e.amount, e.state, e.createdAt, e.updatedAt);
    }

    /// @dev Sprecava slucajno slanje ETH-a direktno na ugovor mimo createEscrow
    receive() external payable {
        revert("ConditionalEscrow: koristite createEscrow()");
    }
}