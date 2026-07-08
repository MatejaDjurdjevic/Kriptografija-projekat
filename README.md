*Conditional Escrow DApp – Smart Contract*

Ovaj projekat predstavlja pametni ugovor za uslovni escrow sistem sa arbitražom. Cilj je da se omogući sigurno deponovanje sredstava između kupca i prodavca, pri čemu se sredstva oslobađaju tek nakon ispunjenja dogovorenih uslova ili nakon odluke arbitra u slučaju spora.

- Opis projekta

ConditionalEscrow omogućava kupcu da kreira escrow transakciju i odmah deponuje ETH u pametni ugovor. Prodavac dobija sredstva tek kada kupac potvrdi prijem robe ili usluge. Ako dođe do neslaganja između kupca i prodavca, jedna od strana može pokrenuti spor, a unapred definisani arbitar donosi konačnu odluku o tome kome se sredstva isplaćuju.

- Glavne funkcionalnosti

- kreiranje i finansiranje escrow-a
- potvrda prijema od strane kupca
- isplata sredstava prodavcu
- dobrovoljni povraćaj sredstava kupcu
- pokretanje spora od strane kupca ili prodavca
- razrešenje spora od strane arbitra
- zaštita od dvostruke isplate
- reentrancy zaštita
- emitovanje događaja radi javne provere transakcija


*Uloge u sistemu*

- **Kupac** – kreira escrow i deponuje sredstva.
- **Prodavac** – prima sredstva nakon potvrde kupca ili može dobrovoljno vratiti sredstva kupcu.
- **Arbitar** – neutralna treća strana koja rešava spor u korist kupca ili prodavca.


*Korišćene tehnologije*

- Solidity 0.8.24
- Remix IDE
- Sepolia test network
- MetaMask

- Deploy na Sepolia mreži

Pametni ugovor je deployovan na Sepolia test mrežu.

*Adresa ugovora:*

```text
0x4a127cda98ddc2a88ed4eb8c76bbaf5f1f381964
