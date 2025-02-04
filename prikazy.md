# Příkazy k zápočtu a zkoušce z předmětu KI/RDBS

## 1. Selecty

### a) Průměrný počet záznamů na jenu tabulku

Tento SELECT využívá tabulky _pg_stat_user_tables_ k získání informací o tzv. "živých záznamech", na základě kterých poté vypoítá průměrný počet záznamů na jednu tabulku.

```sql
-- Obnova dat
ANALYZE;

-- Vezme vsechny vytvorene tabulky v dane databazi a z nich pomoci tabulek vytvarenych postgresem vytvori prumerny pocet
SELECT SUM(n_live_tup)/COUNT(*) AS "Průměrný počet záznamů na tabulku" FROM pg_stat_user_tables;
```

### b) SELECT obsahující vnořený SELECT

Příkaz vybere zaměstnance, kteří nemají aktuálně žádné školení.

```sql
SELECT CONCAT(jmeno, ' ', prijmeni) as jmeno, mobil, mail 
  FROM zamestnanci WHERE id NOT IN 
  (SELECT id_zamestnanec FROM zamestnanci_skoleni);
```

### c) SELECT obsahující analytickou funkci

SELECT vybere z tabulky _zakazky_ všechny zakázky a seskupí je dle stavu, ve kterém aktuálně jsou, k tomu přidá ještě počet zakázek v daném stavu.

```sql
SELECT COUNT(stav) as Statistika, stav FROM zakazky GROUP BY stav;
```

### d) SELECT obsahující hierarchii.
```sql
WITH RECURSIVE hierarchie AS (
	SELECT id, CONCAT(jmeno, ' ', prijmeni) AS jmeno, id_nadrizeneho FROM zamestnanci 
	UNION  
	SELECT z.id, CONCAT(z.jmeno, ' ', z.prijmeni), z.id_nadrizeneho FROM zamestnanci z 
	INNER JOIN hierarchie h ON h.id=z.id_nadrizeneho
)
SELECT * FROM hierarchie;
```

## 2. VIEW

Daný VIEW seskupí tři tabulky: _klienti_, _zakazky_ a _faktury_ a z nich vybere ty nejpodstatnější informace.

```sql
-- Vytvoří view, který nabídne přehled zákazníku, a jejich zakázek a zda již zaplatili fakturu
CREATE VIEW prehled_faktur AS 
  SELECT k.id, k.nazev AS "Nazev klienta", k.mesto, z.kratky_popis
  AS "Nazev zakazky",  f.cislo_faktury, f.zaplaceno FROM klienti k
  JOIN zakazky z ON k.id=id_klient 
  LEFT JOIN faktury f on z.id_faktury = f.id;
```

## 3. INDEX

Jedná se o fulltextový index nad sloupečkem _poznamky_ v tabulce _zakazky_. Daný index podporuje češtinu.

Hodí se například pokud hledáme konkrétní součátsky, které jsou potřebné a jsou zmíněné v poznámkách.

```sql
-- Fulltextovy index nad sloupcem 'kratky_popis' v tabulce zakazky

-- Vytvoreni fulltextoveho indexu, ktery umi pracovat s ceskymi slovy
CREATE INDEX idx_zakazky_poznamky_fulltext ON zakazky USING gin(to_tsvector('czech', poznamky));

-- Nasledne otestovani, zda index funguje
SELECT * FROM zakazky WHERE to_tsvector('czech', poznamky) @@ to_tsquery('czech', 'svítidla');

```

## 4. Function

Funkce vypočítá celkovou částku, jenž je shromážděna ve fakturách, které nejsou vyplaceny.

```sql
CREATE OR REPLACE FUNCTION nevyplacene_faktury() RETURNS Varchar LANGUAGE plpgsql AS $$
DECLARE
  celkova_castka INTEGER;
BEGIN		
  SELECT SUM(CAST(celkova_cena AS DECIMAL))
  INTO celkova_castka 
  FROM faktury 
  WHERE zaplaceno <> TRUE;

  RETURN celkova_castka;
END;
$$;

SELECT nevyplacene_faktury();

-- Vypis vsech procedur, pouze pro kontrolu
\df
```

## 5. Procedure 

Tato procedura vytvoří tabulku, obsahující záznamy faktur, které nebyly k proplaceny k datu, který se proceduře předá přes parametr _datum_. 

```sql
-- Vypocita pocet dni od vyprseni lhuty proplaceni faktur napriklad od aktualniho datumu, 
CREATE OR REPLACE PROCEDURE nezaplacene_faktury_po_splatnosti(datum DATE) LANGUAGE plpgsql AS $$
  DECLARE
    DECLARE date_cursor CURSOR FOR SELECT id, celkova_cena, datum_splatnosti FROM faktury WHERE zaplaceno <> TRUE AND datum_splatnosti < datum;
    da te_interval RECORD;
  BEGIN
    DROP TABLE IF EXISTS faktury_po_splatnosti;

    CREATE TABLE faktury_po_splatnosti(id SERIAL, dni_po INTERVAL, stary_datum_splatnosti DATE, castka VARCHAR(10));
    OPEN date_cursor;

  LOOP

  FETCH NEXT FROM date_cursor INTO date_interval;
  EXIT WHEN NOT FOUND;

  if date_interval.datum_splatnosti < datum THEN
    INSERT INTO faktury_po_splatnosti(dni_po, stary_datum_splatnosti, castka) VALUES(MAKE_INTERVAL(days => datum - date_interval.datum_splatnosti), date_interval.datum_splatnosti, date_interval.celkova_cena);
  END IF;
  END LOOP;

  CLOSE date_cursor;
  EXCEPTION
    WHEN OTHERS THEN
    RAISE NOTICE 'Chyba.... %', SQLERRM;
    RETURN;
END;
$$;

-- Zavolani procedury	
CALL nezaplacene_faktury_po_splatnosti(CURRENT_DATE);
CALL nezaplacene_faktury_po_splatnosti('2025-02-10');

-- Vypis tabulky, kterou procedura vytvori
SELECT * FROM faktury_po_splatnosti ORDER BY dni_po;

```

## 6. Trigger

Tento trigger se spustí pokažde, jakmile skončí jedna z těchto událostí: UPDATE, INSERT, DELETE na tabulce _faktury_. Po vykonání do tabulky _uzivatelska_cinnost_faktury_ zapíše, který uživatel změníl/vložil/odstranil jaký záznam.

```sql
-- After trigger (po zmene) moniturující zmeny v tabulce 'faktury'
CREATE OR REPLACE FUNCTION loggovani() RETURNS trigger LANGUAGE plpgsql 
SECURITY DEFINER -- Bez neho by byla tabulka 'uzivatelska_cinnost_faktury' vlastnena tim, kdo by vytvoril prvni zaznam, takto patri superuzivateli postgres AS $$
  DECLARE
    uzivatelske_jmeno TEXT;
    cas_aktivace TIMESTAMP;	
    pouzity_prikaz RECORD;
    id_radku INT;
  BEGIN
    CREATE TABLE IF NOT EXISTS uzivatelska_cinnost_faktury(id SERIAL, nazev_uctu TEXT, id_radku INT, datum_cas TIMESTAMP, prikaz TEXT, stara_data TEXT, nova_data TEXT);	

    IF OLD.id IS NULL THEN		-- Pokud se jedna o INSERT, nastav id_radku na nove ID
    id_radku = NEW.ID;
    ELSE
    id_radku = OLD.ID;	-- Pokud se jedna o jakoukoliv jinou modifikovaci operaci, id je proste to same
    END IF;
    -- dodelat if osetreni

    INSERT INTO uzivatelska_cinnost_faktury(nazev_uctu, id_radku, datum_cas, prikaz, stara_data, nova_data) VALUES(SESSION_USER, id_radku ,current_timestamp, tg_op, OLD, NEW);
    --  SESSION_USER -> Uzivatel, ktery provedl zmenu,
    -- tg_op -> O jakou zmenu se presne jedna (UPDATE, DELETE, INSERT)

  RETURN NULL;	--  funkce musi neco vratit, vzhledem k tomu, ze vkladame (a vytvarime) do tabulky, nic nevracime

END;
$$;

-- Vytvoreni triggeru, ktery bude reagovat na jakoukoliv zmenu
CREATE TRIGGER loggovani_cinnosti
  AFTER INSERT OR UPDATE OR DELETE on faktury FOR EACH ROW
	EXECUTE FUNCTION loggovani();

	
-- Prihlaseni pres uzivatele, jenz ma pravo menit tabulku 'faktury'
psql -U 'JaroslavaProcházková' -d elektrikari -h localhost 

UPDATE faktury SET cislo_faktury='F350398' WHERE id=19;
DELETE FROM faktury WHERE id=19;

-- Vypis logu 
SELECT * FROM uzivatelska_cinnost_faktury;

-- Testovaci INSERT/UPDATE
INSERT INTO faktury VALUES(20, 1, 'F547895', current_date, '2025-03-15', '50000', false);
DELETE FROM faktury WHERE id=20;
```

## 7. Transaction

Tato transakce upraví záznamy atributu _datum_splatnosti_ v tabulce _faktury_ tak, že k nim přičte (například) 30 dní, vlastně tedy lhůtu prodlouží.

```sql
BEGIN;

  UPDATE faktury SET datum_splatnosti = datum_splatnosti + INTERVAL '30 days' WHERE datum_splatnosti < CURRENT_DATE;

COMMIT;
```

## 8. User

Tento bod je realizován poměrně robustněji - původní myšlenka byla taková, že nahradí proceduru v bodě 5., jelikož nebyla funkční.

Procedura vytváří uživatelské účty zaměstnancům na základě záznamů v tabulce _zamestnanci_. Zároveň přidává zaměstnance do role zamestnanci_ucty, pomocí které se jim globálně spravují pravomoce. Poté je zde i IF větvení, které "povýšeným" zaměstnancům přidává více pravomocí.

```sql
-- Procedura vytvarejici ucty a pristup do databaze na zaklade tabulky 'zamestnanci'
CREATE OR REPLACE PROCEDURE vytvor_zamestnanecke_ucty() LANGUAGE plpgsql AS $$
  DECLARE 
    DECLARE zamestnanec_cursor CURSOR FOR SELECT id, jmeno, prijmeni, id_pozice FROM zamestnanci;
    uzivatel RECORD;
    uzivatelske_jmeno TEXT;
    heslo TEXT;
  BEGIN
    -- Kontrola, zda nahodou dana role jiz v postgre neexistuje
    IF EXISTS (SELECT * FROM pg_roles WHERE rolname = 'zamestnanci_ucty') THEN
      RAISE NOTICE 'Role již existuje!';
    ELSE
      CREATE ROLE zamestnanci_ucty;
      GRANT SELECT ON zakazky TO zamestnanci_ucty;
    GRANT SELECT ON skoleni TO zamestnanci_ucty;
    END IF; 		        

    OPEN zamestnanec_cursor;

    LOOP

    FETCH NEXT FROM zamestnanec_cursor INTO uzivatel;
    EXIT WHEN NOT FOUND;	 

    -- Vytvareni hesla a uzivatelskeho jmena
    heslo = CONCAT(LEFT(uzivatel.prijmeni, 3), LEFT(uzivatel.jmeno, 3));
    uzivatelske_jmeno := CONCAT(uzivatel.jmeno, uzivatel.prijmeni);                      

    -- Kontrola, zda nahodou uzivatelske jmeno neni v nepovolenem tvaru, ktere by vovolalo vyjimku
    IF uzivatelske_jmeno IS NULL OR uzivatelske_jmeno = '' OR heslo IS NULL OR heslo = '' THEN
      RAISE NOTICE 'Neplatné údaje pro vytvoření nového uživatele %!', uzivatel.id;	
    END IF;                       

    -- Pokud uzivatel jiz existuje, preskoc ho a pokud ne, vytvor ho
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = uzivatelske_jmeno) THEN
      RAISE NOTICE 'Uzivatel jiz existuje!';
    ELSE
      -- CREATE USER uzivatelske_jmeno WITH PASSWORD heslo;
      EXECUTE FORMAT('CREATE USER %I PASSWORD %L', uzivatelske_jmeno, heslo); 

      -- pridani uzivatele do role zamestnanci_ucty
      EXECUTE FORMAT('GRANT zamestnanci_ucty TO %I', uzivatelske_jmeno);	
  
      -- GRANT CONNECT ON DATABASE elektrikari TO uzivatelske_jmeno;
      EXECUTE FORMAT('GRANT CONNECT ON DATABASE elektrikari TO %I', uzivatelske_jmeno);
  
      -- TATO CAST NENI JIZ POTREBA VZHLEDEM K ROLI zamestnanci_ucty
      --EXECUTE FORMAT('GRANT SELECT ON zakazky TO %I', uzivatelske_jmeno);
      --EXECUTE FORMAT('GRANT SELECT ON skoleni TO %I', uzivatelske_jmeno);
  
      -- IF podmikny, pridelujici specialni pravomoce, na zaklade pozice daneho zamestnance
      IF uzivatel.id_pozice = 0 THEN
        EXECUTE FORMAT('GRANT INSERT, UPDATE, DELETE, SELECT ON ALL TABLES IN SCHEMA public TO %I', uzivatelske_jmeno);
      ELSIF uzivatel.id_pozice = 1 THEN
        EXECUTE FORMAT('GRANT SELECT ON ALL TABLES IN SCHEMA public TO %I', uzivatelske_jmeno);
        EXECUTE FORMAT('GRANT UPDATE, DELETE, INSERT ON faktury TO %I', uzivatelske_jmeno);     	
      ELSIF uzivatel.id_pozice = 4 THEN	
        EXECUTE FORMAT('GRANT SELECT ON klienti TO %I', uzivatelske_jmeno);
      EXECUTE FORMAT('GRANT SELECT ON zamestnanci TO %I', uzivatelske_jmeno);
      END IF;
    END IF;                                   
    END LOOP;
  CLOSE zamestnanec_cursor;

  EXCEPTION
  -- Pokud nastane jakakoliv neocekavana chyba
  WHEN OTHERS THEN
    RAISE NOTICE 'Chyba.... %', SQLERRM;
    RETURN;
END;
$$;

-- Prihlaseni k databazi pres jineho uzivatele
psql -U 'JaroslavaProcházková' -d elektrikari -h localhost 

```

## 9. Lock

Zámek, který v transakci uzamkne záznamy v tabulce _faktury_, přesněji tedy záznamy, jenž nejsou zaplacené a následně k takovým záznamům přičte "pokutu". 

```sql
BEGIN;

  SELECT * FROM faktury WHERE zaplaceno = False FOR UPDATE;

  UPDATE faktury SET celkova_cena = (faktury.celkova_cena::DECIMAL + 100) WHERE zaplaceno <> True;

COMMIT;
```

## 10. ORM

Tento kód realizuje bod 4. v tomto vypracování, tedy funkci, která počítá celkovou sumu, skrývající se ve fakturách, které nejsou proplaceny.

```python
# Realizace zadani a vypracovani bodu d) Function

# Import knihoven a modulu
from sqlalchemy import create_engine, select, Column, Integer, String, Text, Boolean, Date, ForeignKey, SmallInteger, TIMESTAMP
from sqlalchemy.orm import declarative_base, sessionmaker

# Pripojeni k me databazi za uzivatele 'JaroslavaProcházková', ktery ma urcite pravomoce
db = create_engine('postgresql://JaroslavaProcházková:ProJar@localhost:5432/elektrikari') # Připojení k postgre a k databázi

# Vytvoreni defaultni tridy, obsahujici informace o tabulkach
Base = declarative_base()

# Jednotlive tridy pythonu reprezentuji tabulky v me databazi
class Klient(Base):     
    __tablename__ = 'klienti'

    id = Column(Integer, primary_key=True)
    nazev = Column(String(50))
    telefon = Column(String(9), unique=True)
    mail = Column(String(40), unique=True)
    adresa = Column(String(100))
    mesto = Column(String(38))
    ico = Column(String(9), unique=True)

class Zakazka(Base):
    __tablename__= 'zakazky'

    id = Column(Integer, primary_key=True)
    id_klient = Column(Integer, ForeignKey('klienti.id'))
    kratky_popis = Column(String(150))
    id_faktury = Column(Integer, ForeignKey('faktury.id'))
    stav = Column(String(50))
    datum_zahajeni = Column(TIMESTAMP)
    poznamky = Column(Text)

class Faktura(Base):
    __tablename__ = 'faktury'

    id = Column(Integer, primary_key = True)
    id_typ = Column(SmallInteger)
    cislo_faktury = Column(String(8))
    datum_vystaveni = Column(Date)
    datum_splatnosti = Column(Date)
    celkova_cena = Column(String(10))
    zaplaceno = Column(Boolean)

# Vytvoreni pripojeni k dazabazovemu enginu (db) a nasledna inicializace instance 
Session = sessionmaker(bind=db)    
session = Session()

# Nacte data z tabulky 'faktury'
faktury = session.query(Faktura).all()

# Funkce projde vsechny faktury a spocita celkovou castku, ktere nejsou zaplaceny aktualne
def nevyplacene_faktury_sqlalchemy():
    celkova_castka = 0
    for faktura in faktury:
        if faktura.zaplaceno == False:
            celkova_castka = celkova_castka + float(faktura.celkova_cena)

    print(celkova_castka)    

nevyplacene_faktury_sqlalchemy()
```
