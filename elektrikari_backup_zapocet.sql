--
-- PostgreSQL database dump
--

-- Dumped from database version 14.15 (Ubuntu 14.15-1.pgdg22.04+1)
-- Dumped by pg_dump version 14.15 (Ubuntu 14.15-1.pgdg22.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: loggovani(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.loggovani() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    AS $$
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

		INSERT INTO uzivatelska_cinnost_faktury(nazev_uctu, id_radku, datum_cas, prikaz, stara_data, nova_data) VALUES(SESSION_USER, id_radku ,current_timestamp, tg_op, OLD, NEW);
		-- SESSION_USER -> Uzivatel, ktery provedl zmenu,
		-- tg_op -> O jakou zmenu se presne jedna (UPDATE, DELETE, INSERT)
		
	RETURN NULL;	-- Trigger funkce musi neco vratit, vzhledem k tomu, ze vkladame (a vytvarime) do tabulky, nic nevracime

END;
$$;


ALTER FUNCTION public.loggovani() OWNER TO postgres;

--
-- Name: nevyplacene_faktury(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.nevyplacene_faktury() RETURNS character varying
    LANGUAGE plpgsql
    AS $$
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


ALTER FUNCTION public.nevyplacene_faktury() OWNER TO postgres;

--
-- Name: nezaplacene_faktury_po_splatnosti(date); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.nezaplacene_faktury_po_splatnosti(IN datum date)
    LANGUAGE plpgsql
    AS $$
	DECLARE
		DECLARE date_cursor CURSOR FOR SELECT id, celkova_cena, datum_splatnosti FROM faktury WHERE zaplaceno <> TRUE AND datum_splatnosti < datum;
		date_interval RECORD;
	BEGIN
		DROP TABLE IF EXISTS faktury_po_splatnosti;
		
		CREATE TABLE faktury_po_splatnosti(id SERIAL, dni_po INTERVAL, stary_datum_splatnosti DATE, castka VARCHAR(10));
		OPEN date_cursor;
		
		LOOP
			FETCH NEXT FROM date_cursor INTO date_interval;
			EXIT WHEN NOT FOUND;
			if date_interval.datum_splatnosti < datum THEN INSERT INTO faktury_po_splatnosti(dni_po, stary_datum_splatnosti, castka) VALUES(MAKE_INTERVAL(days => datum - date_interval.datum_splatnosti), date_interval.datum_splatnosti, date_interval.celkova_cena);
	 		END IF;
		END LOOP;
		
		CLOSE date_cursor;
  	EXCEPTION
			WHEN OTHERS THEN
					RAISE NOTICE 'Chyba.... %', SQLERRM;
    			RETURN;
	END;
	$$;


ALTER PROCEDURE public.nezaplacene_faktury_po_splatnosti(IN datum date) OWNER TO postgres;

--
-- Name: smazat_zamestnance(); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.smazat_zamestnance()
    LANGUAGE plpgsql
    AS $$
        DECLARE 
                DECLARE user_cursor CURSOR FOR SELECT usename FROM pg_catalog.pg_user;
                uzivatel RECORD;
        BEGIN
                OPEN user_cursor;
                
                LOOP
                        FETCH NEXT FROM user_cursor INTO uzivatel;
                        EXIT WHEN NOT FOUND;
                                                               
                        IF uzivatel.usename IS NULL OR uzivatel.usename = '' THEN
            			CONTINUE;
        		END IF;
                        
                         IF uzivatel.usename <> 'postgres' THEN
                           RAISE NOTICE 'Mažu uživatele: %', uzivatel.usename;
                        -- pokud funkci volam znovu, potrevuji smazat veskere ucty, abych to mohl udelat, musim uzivatelum sebrat jejich pravomoce
                        	EXECUTE FORMAT('REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM %I', uzivatel.usename);
                        	EXECUTE FORMAT('REVOKE ALL PRIVILEGES ON DATABASE elektrikari FROM %I', uzivatel.usename);
                        	EXECUTE FORMAT('ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM %I', uzivatel.usename);
                        	EXECUTE FORMAT('DROP USER %I', uzivatel.usename);
                        END IF;
                        
                END LOOP;
                CLOSE user_cursor;
		EXCEPTION
			WHEN OTHERS THEN
				RAISE NOTICE 'Chyba.... %', SQLERRM;
				RETURN;
END;
$$;


ALTER PROCEDURE public.smazat_zamestnance() OWNER TO postgres;

--
-- Name: vloz_fakturu(integer, text, date, date, numeric, boolean); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.vloz_fakturu(IN p_id_typ integer, IN p_cislo_faktury text, IN p_datum_vystaveni date, IN p_datum_splatnosti date, IN p_celkova_cena numeric, IN p_zaplaceno boolean)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Zahájení explicitní transakce
    BEGIN
        -- Kontrola duplicity čísla faktury
        IF EXISTS (SELECT 1 FROM faktury WHERE cislo_faktury = p_cislo_faktury) THEN
            RAISE EXCEPTION 'Faktura s číslem % již existuje.', p_cislo_faktury;
        END IF;

        -- Vložení nové faktury
        INSERT INTO faktury (id_typ, cislo_faktury, datum_vystaveni, datum_splatnosti, celkova_cena, zaplaceno)
        VALUES (p_id_typ, p_cislo_faktury, p_datum_vystaveni, p_datum_splatnosti, p_celkova_cena, p_zaplaceno);

        -- Validace: Kontrola kladné hodnoty celkové ceny
        IF p_celkova_cena <= 0 THEN
            RAISE EXCEPTION 'Celková cena faktury musí být kladná. Zadaná hodnota: %', p_celkova_cena;
        END IF;

        -- Potvrzení transakce
        COMMIT;

    EXCEPTION WHEN OTHERS THEN
        -- Vrácení všech změn při chybě
        ROLLBACK;
        RAISE NOTICE 'Transakce byla zrušena kvůli chybě: %', SQLERRM;
    END;
END;
$$;


ALTER PROCEDURE public.vloz_fakturu(IN p_id_typ integer, IN p_cislo_faktury text, IN p_datum_vystaveni date, IN p_datum_splatnosti date, IN p_celkova_cena numeric, IN p_zaplaceno boolean) OWNER TO postgres;

--
-- Name: vloz_fakturu_s_transakci(integer, text, date, date, numeric, boolean); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.vloz_fakturu_s_transakci(IN p_id_typ integer, IN p_cislo_faktury text, IN p_datum_vystaveni date, IN p_datum_splatnosti date, IN p_celkova_cena numeric, IN p_zaplaceno boolean)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Zahájení explicitní transakce
    BEGIN

        -- Kontrola duplicity čísla faktury
        IF EXISTS (SELECT 1 FROM faktury WHERE cislo_faktury = p_cislo_faktury) THEN
            RAISE EXCEPTION 'Faktura s číslem % již existuje.', p_cislo_faktury;
        END IF;

        -- Vložení nové faktury s id_typ
        INSERT INTO faktury (id_typ, cislo_faktury, datum_vystaveni, datum_splatnosti, celkova_cena, zaplaceno)
        VALUES (p_id_typ, p_cislo_faktury, p_datum_vystaveni, p_datum_splatnosti, p_celkova_cena, p_zaplaceno);

        -- Validace: Kontrola kladné hodnoty celkové ceny
        IF p_celkova_cena <= 0 THEN
            RAISE EXCEPTION 'Celková cena faktury musí být kladná. Zadaná hodnota: %', p_celkova_cena;
        END IF;

        -- Potvrzení transakce
        COMMIT;

    EXCEPTION WHEN OTHERS THEN
        -- Vrácení všech změn při chybě
        ROLLBACK;
        RAISE NOTICE 'Transakce byla zrušena kvůli chybě: %', SQLERRM;
    END;
END;
$$;


ALTER PROCEDURE public.vloz_fakturu_s_transakci(IN p_id_typ integer, IN p_cislo_faktury text, IN p_datum_vystaveni date, IN p_datum_splatnosti date, IN p_celkova_cena numeric, IN p_zaplaceno boolean) OWNER TO postgres;

--
-- Name: vytvor_zamestnanecke_ucty(); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.vytvor_zamestnanecke_ucty()
    LANGUAGE plpgsql
    AS $$
        DECLARE 
                DECLARE zamestnanec_cursor CURSOR FOR SELECT id, jmeno, prijmeni, id_pozice FROM zamestnanci;
                uzivatel RECORD;
                uzivatelske_jmeno TEXT;
                heslo TEXT;
        BEGIN-- Kontrola, zda nahodou dana role jiz v postgre neexistuje
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


ALTER PROCEDURE public.vytvor_zamestnanecke_ucty() OWNER TO postgres;

--
-- Name: vytvor_zamestnanecke_ucty_transaction(); Type: PROCEDURE; Schema: public; Owner: postgres
--

CREATE PROCEDURE public.vytvor_zamestnanecke_ucty_transaction()
    LANGUAGE plpgsql
    AS $$
        DECLARE 
                DECLARE zamestnanec_cursor CURSOR FOR SELECT id, jmeno, prijmeni, id_pozice FROM zamestnanci;
                uzivatel RECORD;
                uzivatelske_jmeno TEXT;
                heslo TEXT;
        BEGIN -- zacatek kodu procedury
        	BEGIN -- zacatek kodu transakce
        		LOCK TABLE zamestnanci IN EXCLUSIVE MODE; -- Zamknuti tabulky pro jakekoliv upravy ostatnim transakcim a uzivatelum, je povolene pouze cteni
        			-- hodi se napriklad kvuli id_pozice, ktera kdyby se za behu menila, uzivatel by mohl zustat bez prav, ktera mu nalezi 
        	
		        
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
                COMMIT;
			EXCEPTION
                WHEN OTHERS THEN
            		ROLLBACK;
            		RAISE NOTICE 'Chyba: %', SQLERRM;
            END;
END;
$$;


ALTER PROCEDURE public.vytvor_zamestnanecke_ucty_transaction() OWNER TO postgres;

--
-- Name: czech_spell; Type: TEXT SEARCH DICTIONARY; Schema: public; Owner: postgres
--

CREATE TEXT SEARCH DICTIONARY public.czech_spell (
    TEMPLATE = pg_catalog.ispell,
    dictfile = 'czech', afffile = 'czech', stopwords = 'czech' );


ALTER TEXT SEARCH DICTIONARY public.czech_spell OWNER TO postgres;

--
-- Name: czech; Type: TEXT SEARCH CONFIGURATION; Schema: public; Owner: postgres
--

CREATE TEXT SEARCH CONFIGURATION public.czech (
    PARSER = pg_catalog."default" );

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR asciiword WITH public.czech_spell, simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR word WITH public.czech_spell, simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR numword WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR email WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR url WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR host WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR sfloat WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR version WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR hword_numpart WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR hword_part WITH english_stem;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR hword_asciipart WITH english_stem;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR numhword WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR asciihword WITH english_stem;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR hword WITH english_stem;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR url_path WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR file WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR "float" WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR "int" WITH simple;

ALTER TEXT SEARCH CONFIGURATION public.czech
    ADD MAPPING FOR uint WITH simple;


ALTER TEXT SEARCH CONFIGURATION public.czech OWNER TO postgres;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: faktury; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.faktury (
    id integer NOT NULL,
    id_typ smallint,
    cislo_faktury character varying(8),
    datum_vystaveni date,
    datum_splatnosti date,
    celkova_cena character varying(10),
    zaplaceno boolean
);


ALTER TABLE public.faktury OWNER TO postgres;

--
-- Name: faktury_po_splatnosti; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.faktury_po_splatnosti (
    id integer NOT NULL,
    dni_po interval,
    stary_datum_splatnosti date,
    castka character varying(10)
);


ALTER TABLE public.faktury_po_splatnosti OWNER TO postgres;

--
-- Name: faktury_po_splatnosti_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.faktury_po_splatnosti_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.faktury_po_splatnosti_id_seq OWNER TO postgres;

--
-- Name: faktury_po_splatnosti_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.faktury_po_splatnosti_id_seq OWNED BY public.faktury_po_splatnosti.id;


--
-- Name: klienti; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.klienti (
    id integer NOT NULL,
    nazev character varying(50),
    telefon character varying(9),
    mail character varying(40),
    adresa character varying(100),
    mesto character varying(38),
    ico character varying(9)
);


ALTER TABLE public.klienti OWNER TO postgres;

--
-- Name: pozice; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.pozice (
    id smallint NOT NULL,
    nazev character varying(20),
    plat character varying(6)
);


ALTER TABLE public.pozice OWNER TO postgres;

--
-- Name: zakazky; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.zakazky (
    id integer NOT NULL,
    id_klient integer,
    kratky_popis character varying(150),
    id_faktury integer,
    stav character varying(50),
    datum_zahajeni timestamp without time zone,
    poznamky text
);


ALTER TABLE public.zakazky OWNER TO postgres;

--
-- Name: prehled_faktur; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.prehled_faktur AS
 SELECT k.id,
    k.nazev AS "Nazev klienta",
    k.mesto,
    z.kratky_popis AS "Nazev zakazky",
    f.cislo_faktury,
    f.zaplaceno
   FROM ((public.klienti k
     JOIN public.zakazky z ON ((k.id = z.id_klient)))
     LEFT JOIN public.faktury f ON ((z.id_faktury = f.id)));


ALTER TABLE public.prehled_faktur OWNER TO postgres;

--
-- Name: skoleni; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.skoleni (
    id integer NOT NULL,
    nazev character varying(200),
    cena character varying(6),
    doba_platnosti interval
);


ALTER TABLE public.skoleni OWNER TO postgres;

--
-- Name: typ_zakazky; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.typ_zakazky (
    id smallint NOT NULL,
    nazev character varying(100),
    popis text,
    opakujici_se boolean
);


ALTER TABLE public.typ_zakazky OWNER TO postgres;

--
-- Name: uzivatelska_cinnost_faktury; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.uzivatelska_cinnost_faktury (
    id integer NOT NULL,
    nazev_uctu text,
    id_radku integer,
    datum_cas timestamp without time zone,
    prikaz text,
    stara_data text,
    nova_data text
);


ALTER TABLE public.uzivatelska_cinnost_faktury OWNER TO postgres;

--
-- Name: uzivatelska_cinnost_faktury_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.uzivatelska_cinnost_faktury_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.uzivatelska_cinnost_faktury_id_seq OWNER TO postgres;

--
-- Name: uzivatelska_cinnost_faktury_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.uzivatelska_cinnost_faktury_id_seq OWNED BY public.uzivatelska_cinnost_faktury.id;


--
-- Name: zamestnanci; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.zamestnanci (
    id smallint NOT NULL,
    jmeno character varying(20),
    prijmeni character varying(50),
    id_pozice smallint,
    mobil character varying(9),
    mail character varying(40),
    id_nadrizeneho smallint
);


ALTER TABLE public.zamestnanci OWNER TO postgres;

--
-- Name: zamestnanci_skoleni; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.zamestnanci_skoleni (
    id_zamestnanec smallint,
    id_skoleni smallint,
    datum_absolvovani date
);


ALTER TABLE public.zamestnanci_skoleni OWNER TO postgres;

--
-- Name: zamestnanci_zakazky; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.zamestnanci_zakazky (
    id_zamestnance smallint,
    id_zakazky integer
);


ALTER TABLE public.zamestnanci_zakazky OWNER TO postgres;

--
-- Name: faktury_po_splatnosti id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.faktury_po_splatnosti ALTER COLUMN id SET DEFAULT nextval('public.faktury_po_splatnosti_id_seq'::regclass);


--
-- Name: uzivatelska_cinnost_faktury id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.uzivatelska_cinnost_faktury ALTER COLUMN id SET DEFAULT nextval('public.uzivatelska_cinnost_faktury_id_seq'::regclass);


--
-- Data for Name: faktury; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.faktury (id, id_typ, cislo_faktury, datum_vystaveni, datum_splatnosti, celkova_cena, zaplaceno) FROM stdin;
5	4	F113715	2025-01-13	2025-02-12	26552.00	t
8	8	F784962	2025-01-11	2025-02-10	28267.00	t
1	0	F198394	2024-12-20	2025-02-18	39994.00	t
3	4	F727789	2024-12-30	2025-02-28	14591.00	t
7	2	F637551	2024-12-29	2025-02-27	9452.00	t
9	5	F506877	2024-12-27	2025-02-25	16805.00	t
14	0	F139782	2025-01-02	2025-03-03	3164.00	t
18	5	F390915	2024-12-28	2025-02-26	18684.00	t
4	8	F617033	2025-01-07	2025-02-06	28070.00	f
13	6	F765814	2025-01-14	2025-02-13	6921.00	f
19	7	F354000	2024-12-01	2025-01-30	3159.00	f
0	1	F976199	2025-01-03	2025-03-04	33694.00	f
6	8	F268647	2025-01-04	2025-03-05	38954.00	f
10	5	F361534	2025-01-01	2025-03-02	21702.00	f
11	7	F587894	2025-01-03	2025-03-04	34282.00	f
12	8	F133699	2024-12-26	2025-02-24	41157.00	f
15	2	F260450	2024-12-25	2025-02-23	39589.00	f
16	3	F313151	2025-01-03	2025-03-04	40222.00	f
2	6	F780637	2025-01-05	2025-02-04	41446.00	t
17	6	F280753	2024-12-22	2025-02-20	17264.00	f
\.


--
-- Data for Name: faktury_po_splatnosti; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.faktury_po_splatnosti (id, dni_po, stary_datum_splatnosti, castka) FROM stdin;
1	5 days	2025-01-30	3059.00
\.


--
-- Data for Name: klienti; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.klienti (id, nazev, telefon, mail, adresa, mesto, ico) FROM stdin;
0	Aleš Veselý	740142926	ales.vesely@seznam.cz	Lipová 498	Teplice	88879049
1	David Svoboda	583679072	david.svoboda@email.cz	Sportovní 565	Děčín	61829609
2	Aleš Král	867208346	ales.kral@gmail.com	Polní 256	Most	15613315
3	Filip Jelínek	755869088	filip.jelinek@email.cz	Masarykova 875	Ústí nad Labem	98562716
4	Tomáš Svoboda	223194336	tomas.svoboda@seznam.cz	Lipová 221	Litvínov	19762698
5	Lukáš Král	441736604	lukas.kral@email.cz	Krátká 501	Litvínov	51708236
6	Jaroslav Jelínek	772173128	jaroslav.jelinek@gmail.com	Husova 578	Ústí nad Labem	86638602
7	Roman Němec	098161156	roman.nemec@seznam.cz	Krátká 873	Most	81500871
8	Tomáš Pokorný	884701676	tomas.pokorny@gmail.com	Zelená 919	Litvínov	55863674
9	Václav Fiala	340631960	vaclav.fiala@post.cz	Dlouhá 311	Chomutov	67110899
10	BD Severní	605789123	bd.severni@seznam.cz	Severní 452	Ústí nad Labem	45678123
11	SVJ Klíšská	776234567	svj.klisska@email.cz	Klíšská 789	Ústí nad Labem	89012345
12	Martin Dvořák	608147258	martin.dvorak@gmail.com	Revoluční 147	Teplice	23158789
13	Pekařství Sládek	773951852	pekarstvi.sladek@post.cz	Náměstí 123	Most	04507800
14	Karel Novotný	602369147	karel.novotny@seznam.cz	Školní 852	Děčín	00174901
15	Restaurace U Lípy	775159753	restaurace.lipa@email.cz	Míru 456	Chomutov	56789012
16	Petr Malý	608741852	petr.maly@gmail.com	Horská 789	Litvínov	67890123
17	SVJ Mírová	776951357	svj.mirova@post.cz	Mírová 321	Most	78901234
18	Autoservis Rychlý	602147258	autoservis.rychly@seznam.cz	Průmyslová 654	Teplice	89418345
19	Jana Veselá	773369147	jana.vesela@email.cz	Lipová 987	Děčín	90123456
20	SBDMIR	745554202	sbdmir@druzstvo.cz	Gagarinova 1158	Teplice	00035351
\.


--
-- Data for Name: pozice; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.pozice (id, nazev, plat) FROM stdin;
0	vedouci	50000
1	ucetni	35000
2	zamestnanenc	30000
3	brigadnik	21000
4	asistent	30000
5	ucen	\N
\.


--
-- Data for Name: skoleni; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.skoleni (id, nazev, cena, doba_platnosti) FROM stdin;
0	Základní školení pro montéry elektrických instalací	4500	1 year
1	Pokročilé školení na montáž rozvaděčů	5200	2 years
2	Školení revizních techniků pro silnoproudá zařízení	8000	3 years
3	Kurz bezpečnosti práce při práci s VN zařízeními	6000	1 year
4	Montáž a údržba hromosvodů – praktický kurz	5500	2 years
5	Instalace fotovoltaických systémů – základní kurz	7000	1 year 6 mons
6	Montáž dobíjecích stanic pro elektromobily	7500	2 years
7	Školení na inteligentní elektroinstalace v budovách	6700	3 years
8	Obsluha a údržba VN transformátorů	9000	2 years
9	Odborná způsobilost dle NV č. 194/2022 Sb. §6 a §7	3200	1 year
\.


--
-- Data for Name: typ_zakazky; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.typ_zakazky (id, nazev, popis, opakujici_se) FROM stdin;
0	Montáž	Provádění montážních prací na elektroinstalacích.	f
1	Revize	Kontrola a revize elektrických zařízení.	t
2	Instalace	Instalace nových elektrických systémů.	f
3	Údržba	Pravidelná údržba elektrických zařízení.	t
4	Oprava	Opravy poruch na elektrických zařízeních.	f
5	Modernizace	Modernizace a upgrade stávajících systémů.	f
6	Diagnostika	Diagnostika problémů v elektrických obvodech.	f
7	Testování	Testování elektrických zařízení a systémů.	t
8	Projektování	Návrh a projektování elektrických systémů.	f
\.


--
-- Data for Name: uzivatelska_cinnost_faktury; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.uzivatelska_cinnost_faktury (id, nazev_uctu, id_radku, datum_cas, prikaz, stara_data, nova_data) FROM stdin;
1	JaroslavaProcházková	19	2025-02-04 09:40:50.714073	UPDATE	(19,7,F354398,2024-12-01,2024-12-31,3059.00,f)	(19,7,F350398,2024-12-01,2024-12-31,3059.00,f)
2	postgres	19	2025-02-04 13:54:22.832489	UPDATE	(19,7,F350398,2024-12-01,2024-12-31,3059.00,f)	(19,7,F350798,2024-12-01,2024-12-31,3059.00,f)
3	JaroslavaProcházková	19	2025-02-04 13:55:33.460791	UPDATE	(19,7,F350798,2024-12-01,2024-12-31,3059.00,f)	(19,7,F350798,2024-12-01,2024-12-31,3059.00,f)
4	JaroslavaProcházková	19	2025-02-04 13:56:31.255582	UPDATE	(19,7,F350798,2024-12-01,2024-12-31,3059.00,f)	(19,7,F354798,2024-12-01,2024-12-31,3059.00,f)
5	JaroslavaProcházková	19	2025-02-04 13:57:16.9184	UPDATE	(19,7,F354798,2024-12-01,2024-12-31,3059.00,f)	(19,7,F354000,2024-12-01,2024-12-31,3059.00,f)
6	JaroslavaProcházková	19	2025-02-04 13:57:27.624216	UPDATE	(19,7,F354000,2024-12-01,2024-12-31,3059.00,f)	(19,7,F354000,2024-12-01,2024-12-31,3059.00,f)
7	JaroslavaProcházková	20	2025-02-04 14:02:57.706912	INSERT	\N	(20,1,F547895,2025-02-04,2025-03-15,50000,f)
8	JaroslavaProcházková	20	2025-02-04 14:03:28.753591	DELETE	(20,1,F547895,2025-02-04,2025-03-15,50000,f)	\N
9	postgres	19	2025-02-04 14:16:30.212479	UPDATE	(19,7,F354000,2024-12-01,2024-12-31,3059.00,f)	(19,7,F354000,2024-12-01,2025-01-30,3059.00,f)
10	postgres	1	2025-02-04 14:16:30.212479	UPDATE	(1,0,F198394,2024-12-20,2025-01-19,39994.00,t)	(1,0,F198394,2024-12-20,2025-02-18,39994.00,t)
11	postgres	3	2025-02-04 14:16:30.212479	UPDATE	(3,4,F727789,2024-12-30,2025-01-29,14591.00,t)	(3,4,F727789,2024-12-30,2025-02-28,14591.00,t)
12	postgres	7	2025-02-04 14:16:30.212479	UPDATE	(7,2,F637551,2024-12-29,2025-01-28,9452.00,t)	(7,2,F637551,2024-12-29,2025-02-27,9452.00,t)
13	postgres	9	2025-02-04 14:16:30.212479	UPDATE	(9,5,F506877,2024-12-27,2025-01-26,16805.00,t)	(9,5,F506877,2024-12-27,2025-02-25,16805.00,t)
14	postgres	14	2025-02-04 14:16:30.212479	UPDATE	(14,0,F139782,2025-01-02,2025-02-01,3164.00,t)	(14,0,F139782,2025-01-02,2025-03-03,3164.00,t)
15	postgres	18	2025-02-04 14:16:30.212479	UPDATE	(18,5,F390915,2024-12-28,2025-01-27,18684.00,t)	(18,5,F390915,2024-12-28,2025-02-26,18684.00,t)
16	postgres	0	2025-02-04 14:16:30.212479	UPDATE	(0,1,F976199,2025-01-03,2025-02-02,33594.00,f)	(0,1,F976199,2025-01-03,2025-03-04,33594.00,f)
17	postgres	6	2025-02-04 14:16:30.212479	UPDATE	(6,8,F268647,2025-01-04,2025-02-03,38854.00,f)	(6,8,F268647,2025-01-04,2025-03-05,38854.00,f)
18	postgres	10	2025-02-04 14:16:30.212479	UPDATE	(10,5,F361534,2025-01-01,2025-01-31,21602.00,f)	(10,5,F361534,2025-01-01,2025-03-02,21602.00,f)
19	postgres	11	2025-02-04 14:16:30.212479	UPDATE	(11,7,F587894,2025-01-03,2025-02-02,34182.00,f)	(11,7,F587894,2025-01-03,2025-03-04,34182.00,f)
20	postgres	12	2025-02-04 14:16:30.212479	UPDATE	(12,8,F133699,2024-12-26,2025-01-25,41057.00,f)	(12,8,F133699,2024-12-26,2025-02-24,41057.00,f)
21	postgres	15	2025-02-04 14:16:30.212479	UPDATE	(15,2,F260450,2024-12-25,2025-01-24,39489.00,f)	(15,2,F260450,2024-12-25,2025-02-23,39489.00,f)
22	postgres	16	2025-02-04 14:16:30.212479	UPDATE	(16,3,F313151,2025-01-03,2025-02-02,40122.00,f)	(16,3,F313151,2025-01-03,2025-03-04,40122.00,f)
23	postgres	17	2025-02-04 14:16:30.212479	UPDATE	(17,6,F280753,2024-12-22,2025-01-21,17164.00,f)	(17,6,F280753,2024-12-22,2025-02-20,17164.00,f)
24	postgres	4	2025-02-04 14:20:34.284087	UPDATE	(4,8,F617033,2025-01-07,2025-02-06,27970.00,f)	(4,8,F617033,2025-01-07,2025-02-06,28070.00,f)
25	postgres	13	2025-02-04 14:20:34.284087	UPDATE	(13,6,F765814,2025-01-14,2025-02-13,6821.00,f)	(13,6,F765814,2025-01-14,2025-02-13,6921.00,f)
26	postgres	19	2025-02-04 14:20:34.284087	UPDATE	(19,7,F354000,2024-12-01,2025-01-30,3059.00,f)	(19,7,F354000,2024-12-01,2025-01-30,3159.00,f)
27	postgres	0	2025-02-04 14:20:34.284087	UPDATE	(0,1,F976199,2025-01-03,2025-03-04,33594.00,f)	(0,1,F976199,2025-01-03,2025-03-04,33694.00,f)
28	postgres	6	2025-02-04 14:20:34.284087	UPDATE	(6,8,F268647,2025-01-04,2025-03-05,38854.00,f)	(6,8,F268647,2025-01-04,2025-03-05,38954.00,f)
29	postgres	10	2025-02-04 14:20:34.284087	UPDATE	(10,5,F361534,2025-01-01,2025-03-02,21602.00,f)	(10,5,F361534,2025-01-01,2025-03-02,21702.00,f)
30	postgres	11	2025-02-04 14:20:34.284087	UPDATE	(11,7,F587894,2025-01-03,2025-03-04,34182.00,f)	(11,7,F587894,2025-01-03,2025-03-04,34282.00,f)
31	postgres	12	2025-02-04 14:20:34.284087	UPDATE	(12,8,F133699,2024-12-26,2025-02-24,41057.00,f)	(12,8,F133699,2024-12-26,2025-02-24,41157.00,f)
32	postgres	15	2025-02-04 14:20:34.284087	UPDATE	(15,2,F260450,2024-12-25,2025-02-23,39489.00,f)	(15,2,F260450,2024-12-25,2025-02-23,39589.00,f)
33	postgres	16	2025-02-04 14:20:34.284087	UPDATE	(16,3,F313151,2025-01-03,2025-03-04,40122.00,f)	(16,3,F313151,2025-01-03,2025-03-04,40222.00,f)
34	postgres	17	2025-02-04 14:20:34.284087	UPDATE	(17,6,F280753,2024-12-22,2025-02-20,17164.00,f)	(17,6,F280753,2024-12-22,2025-02-20,17264.00,f)
\.


--
-- Data for Name: zakazky; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.zakazky (id, id_klient, kratky_popis, id_faktury, stav, datum_zahajeni, poznamky) FROM stdin;
0	3	Instalace zásuvek v kanceláři	0	Dokončeno	2025-01-03 10:00:00	Instalováno 8 zásuvek
1	7	Oprava jističů v rodinném domě	\N	Probíhá	2025-01-08 14:30:00	\N
3	10	Kontrola elektroinstalace	1	Dokončeno	2024-12-20 11:00:00	Všechny obvody v pořádku
4	5	Instalace domovního zvonku	\N	Čeká na díly	2025-01-15 16:00:00	\N
5	2	Výpadek proudu - diagnostika	\N	Probíhá	2025-01-14 08:00:00	Pravděpodobná příčina: vadný kabel
6	18	Přidání jističe pro nový spotřebič	2	Dokončeno	2025-01-05 10:30:00	\N
8	11	Oprava kuchyňských zásuvek	3	Dokončeno	2024-12-30 09:00:00	\N
9	6	Zapojení bojleru	4	Dokončeno	2025-01-07 15:00:00	Bojler typu Ariston zapojen a testován
10	15	Revize elektroinstalace v hotelu	\N	Probíhá	2025-01-02 10:00:00	Hodně zastaralé vedení, doporučeno vyměnit
11	12	Oprava světel v garáži	5	Dokončeno	2025-01-13 14:00:00	\N
12	4	Zapojení průmyslového rozvaděče	6	Dokončeno	2025-01-04 08:00:00	Dokončeno rychleji díky prefabrikovaným dílům
13	17	Oprava zásuvek po požáru	\N	Probíhá	2025-01-09 10:00:00	Některé obvody nefunkční, probíhá diagnostika
14	9	Montáž osvětlení v obýváku	7	Dokončeno	2024-12-29 12:00:00	\N
16	14	Zapojení solárního systému	8	Dokončeno	2025-01-11 11:00:00	Plně funkční, testováno na výkon 5 kWp
17	20	Přidání zásuvek v dětském pokoji	9	Dokončeno	2024-12-27 15:30:00	\N
18	16	Přepojení kabelů v panelovém domě	\N	Probíhá	2025-01-10 09:00:00	Práce na třetím patře téměř dokončena
19	13	Oprava elektroinstalace po rekonstrukci	\N	Čeká na schválení	2025-01-19 14:00:00	Klient požaduje přidání dalších prvků
20	1	Výpadek světel v restauraci	10	Dokončeno	2025-01-01 19:00:00	\N
21	7	Instalace nových jističů	11	Dokončeno	2025-01-03 13:00:00	\N
23	8	Instalace venkovního osvětlení	\N	Čeká na schválení	2025-01-17 09:00:00	\N
24	5	Zapojení zásuvky pro klimatizaci	12	Dokončeno	2024-12-26 14:30:00	Instalace trvala 2 hodiny
25	10	Oprava přerušovaných výpadků	\N	Čeká na schválení	2025-01-12 10:00:00	Potřebné další testování
26	11	Zapojení nového osvětlení v kuchyni	\N	Probíhá	2025-01-07 16:00:00	Použity LED panely
27	2	Oprava rozvaděče v kancelářích	13	Dokončeno	2025-01-14 11:30:00	\N
28	6	Instalace nouzového osvětlení	\N	Čeká na schválení	2025-01-09 12:00:00	Vyžaduje speciální certifikované LED
29	2	Diagnostika výpadků	14	Dokončeno	2025-01-02 10:30:00	Problém odstraněn na místě
30	15	Zapojení podlahového vytápění	15	Dokončeno	2024-12-25 08:00:00	\N
32	14	Připojení průmyslového stroje	\N	Čeká na schválení	2025-01-16 10:00:00	\N
33	9	Montáž venkovní elektroinstalace	16	Dokončeno	2025-01-03 13:00:00	\N
34	20	Diagnostika elektrického výpadku	\N	Probíhá	2025-01-15 10:00:00	Vada na hlavním přívodu
35	12	Zapojení osvětlení ve skladu	17	Dokončeno	2024-12-22 14:00:00	Použit LED pásky s vysokým výkonem
37	1	Oprava elektrických obvodů v koupelně	18	Dokončeno	2024-12-28 10:00:00	\N
39	13	Instalace zabezpečovacího systému	19	Dokončeno	2024-12-01 15:00:00	\N
7	8	Rozvody elektřiny pro přístavbu	\N	Čeká na schválení	2025-01-18 13:00:00	Během realizace elektroinstalace pro přístavbu bylo zjištěno, že stávající hlavní přívod elektřiny do budovy nemá dostatečnou kapacitu pro pokrytí nově plánovaného zatížení. Přístavba zahrnuje několik energeticky náročných zařízení, jako jsou klimatizační jednotky, elektrické vytápění a kuchyňské spotřebiče, což výrazně navyšuje celkové požadavky na příkon. Stávající přívodní kabely a jističe nejsou dimenzovány na plánované zatížení, což by mohlo vést k přetížení sítě, výpadkům nebo dokonce k bezpečnostním rizikům, jako je přehřívání kabelů.
22	19	Revize a připojení nových zařízení	\N	Čeká na díly	2025-01-15 11:00:00	Během realizace zakázky na revizi a připojení nových zařízení bylo zjištěno, že některé klíčové certifikované komponenty, nezbytné pro bezpečné připojení zařízení, nejsou aktuálně dostupné. Konkrétně se jedná o Proudové chrániče typu 30 mA, které jsou vyžadovány pro ochranu nově instalovaných zařízení, Konektory pro průmyslové zásuvky, které odpovídají specifikacím připojovaných zařízení, Ochranné kryty rozvaděče, které splňují bezpečnostní normy. Dodavatel těchto komponent oznámil, že kvůli problémům s logistikou a vysoké poptávce budou díly dostupné nejdříve za 10 dní. Tento problém způsobuje zpoždění v dokončení revize a následného připojení zařízení, protože bez těchto certifikovaných dílů nelze zajistit bezpečný provoz.
2	15	Montáž osvětlení v hale	\N	Čeká na schválení	2025-01-12 09:00:00	Během realizace zakázky na montáž osvětlení v hale bylo zjištěno, že některé klíčové komponenty potřebné pro dokončení instalace nejsou aktuálně dostupné. Konkrétně se jedná o Průmyslová LED svítidla, která byla objednána podle specifikací projektu, Montážní konzole a závěsy, nutné k upevnění svítidel na konstrukci haly, Napájecí zdroje pro LED svítidla, které zajišťují správnou funkčnost a bezpečnost systému. Dodavatel oznámil, že kvůli zpožděním v dodavatelském řetězci a vysoké poptávce budou tyto komponenty doručeny nejdříve za 12 dní. Tento problém znemožňuje pokračovat v montáži osvětlení, protože bez těchto dílů nelze provést instalaci ani zapojení svítidel.
38	17	Revize a zapojení serverového rozvaděče	\N	Čeká na díly	2025-01-11 12:00:00	Během realizace zakázky na revizi a zapojení serverového rozvaděče bylo zjištěno, že klíčová komponenta – přepěťová ochrana typu T2 – není aktuálně dostupná. Tato komponenta je nezbytná pro zajištění ochrany serverového rozvaděče před přepětím způsobeným atmosférickými vlivy nebo spínacími procesy v elektrické síti. Dodavatel oznámil, že přepěťová ochrana bude k dispozici nejdříve za 10 dní, což způsobuje zpoždění v dokončení zakázky. Bez této ochrany nelze zajistit bezpečné zapojení serverového rozvaděče ani provést závěrečnou revizi.
36	18	Kontrola starých rozvodů	\N	Čeká na schválení	2025-01-06 13:00:00	Při kontrole starých rozvodů bylo zjištěno, že vodiče v několika patrech (konkrétně ve 2. a 3. patře) jsou v havarijním stavu a vyžadují okamžitou výměnu.
15	3	Instalace podlahového topení	\N	Čeká na díly	2025-01-06 10:00:00	Práce na instalaci podlahového topení byly pozastaveny kvůli komplikacím při pokládání topných kabelů. Byly zjištěny problémy s nerovným podkladem a nedostatkem fixačních prvků, což brání správnému upevnění kabelů. Oprava podkladu a dodávka chybějících materiálů jsou nezbytné pro pokračování prací.
31	4	Revize a oprava hlavního jističe	\N	Čeká na díly	2025-01-08 15:00:00	Během realizace zakázky na revizi a opravu hlavního jističe bylo zjištěno, že klíčová komponenta – hlavní jistič odpovídající specifikaci projektu – není aktuálně skladem. Tento jistič je nezbytný pro bezpečný provoz odběrného místa a jeho absence znemožňuje dokončení opravy. Dodavatel oznámil, že dodávka požadovaného jističe bude možná nejdříve za 10 dní. Bez této komponenty nelze provést výměnu ani dokončit revizní zprávu, což způsobuje zpoždění celé zakázky.
\.


--
-- Data for Name: zamestnanci; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.zamestnanci (id, jmeno, prijmeni, id_pozice, mobil, mail, id_nadrizeneho) FROM stdin;
15	Marek	Král	0	654663118	marek.kral@eleusti.com	\N
1	Jan	Novák	2	691615124	jan.novak@eleusti.com	15
2	Petr	Svoboda	2	692614717	petr.svoboda@eleusti.com	15
3	Josef	Novotný	2	687082371	josef.novotny@eleusti.com	15
4	Martin	Dvořák	2	678047533	martin.dvorak@eleusti.com	15
6	Jaroslava	Procházková	1	603842161	jaroslava.prochazkova@eleusti.com	15
7	Miroslav	Kučera	2	666443808	miroslav.kucera@eleusti.com	15
8	Zdeněk	Veselý	2	639849767	zdenek.vesely@eleusti.com	15
9	Václav	Horák	2	604437552	vaclav.horak@eleusti.com	15
10	Karel	Němec	2	612594457	karel.nemec@eleusti.com	15
12	Jakub	Marek	2	622918406	jakub.marek@eleusti.com	15
16	Vladimír	Jelínek	2	687121619	vladimir.jelinek@eleusti.com	15
17	Filip	Růžička	2	672621045	filip.ruzicka@eleusti.com	15
18	David	Beneš	2	698544800	david.benes@eleusti.com	15
20	Roman	Sedláček	2	690178602	roman.sedlacek@eleusti.com	15
19	Alena	Fiala	4	672151806	alena.fiala@eleusti.com	15
5	Tomáš	Černý	3	631327339	tomas.cerny@eleusti.com	3
13	Ondřej	Pospíšil	3	679860978	ondrej.pospisil@eleusti.com	8
14	Radek	Hájek	3	624955229	radek.hajek@eleusti.com	18
11	Lukáš	Pokorný	5	635981855	lukas.pokorny@eleusti.com	3
\.


--
-- Data for Name: zamestnanci_skoleni; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.zamestnanci_skoleni (id_zamestnanec, id_skoleni, datum_absolvovani) FROM stdin;
1	1	2023-06-15
1	3	2023-09-20
1	4	2024-01-10
2	1	2023-05-12
2	2	2023-08-15
2	4	2024-02-01
2	7	2023-11-30
3	1	2023-07-20
3	3	2023-10-15
3	4	2024-01-05
4	2	2023-04-18
4	4	2023-08-22
4	7	2023-12-10
5	1	2023-03-25
5	3	2023-09-12
5	4	2024-01-15
5	8	2023-11-20
7	1	2023-04-15
7	3	2023-08-20
7	4	2023-12-05
7	8	2024-02-15
8	2	2023-06-10
8	4	2023-09-25
8	7	2024-01-20
9	1	2023-07-05
9	3	2023-10-10
9	4	2024-02-05
10	2	2023-05-20
10	4	2023-08-25
10	7	2023-12-15
10	8	2024-01-25
11	1	2023-04-25
11	3	2023-09-15
11	4	2024-01-30
12	2	2023-06-20
12	4	2023-10-25
12	7	2024-02-20
13	1	2023-07-25
13	3	2023-11-15
13	4	2024-01-05
13	8	2023-12-20
14	2	2023-05-15
14	4	2023-09-30
14	7	2024-01-15
15	1	2023-06-25
15	3	2023-10-20
15	4	2024-02-25
16	2	2023-04-30
16	4	2023-08-15
16	7	2023-12-25
16	8	2024-02-10
17	1	2023-07-15
17	3	2023-11-20
17	4	2024-01-25
18	2	2023-05-25
18	4	2023-09-15
18	7	2024-02-15
20	2	2023-07-20
20	4	2023-11-25
20	7	2024-02-28
\.


--
-- Data for Name: zamestnanci_zakazky; Type: TABLE DATA; Schema: public; Owner: postgres
--

COPY public.zamestnanci_zakazky (id_zamestnance, id_zakazky) FROM stdin;
14	0
2	0
3	1
4	1
5	2
6	2
7	2
8	3
4	3
10	4
11	4
12	4
13	5
14	5
16	5
17	6
18	6
20	7
2	7
3	7
4	8
5	8
6	9
7	9
8	10
10	10
11	11
12	11
13	12
14	12
16	13
17	13
18	14
4	14
2	15
3	15
4	16
5	16
6	17
7	17
8	18
10	18
11	19
12	19
13	20
14	20
16	21
17	21
18	22
11	22
2	23
3	23
4	24
5	24
6	25
7	25
8	26
10	26
11	27
12	27
13	28
14	28
16	29
17	29
18	30
2	30
2	31
3	31
4	32
5	32
6	33
7	33
8	34
10	34
11	35
12	35
13	36
14	36
16	37
17	37
18	38
2	38
2	39
3	39
4	39
5	39
\.


--
-- Name: faktury_po_splatnosti_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.faktury_po_splatnosti_id_seq', 1, true);


--
-- Name: uzivatelska_cinnost_faktury_id_seq; Type: SEQUENCE SET; Schema: public; Owner: postgres
--

SELECT pg_catalog.setval('public.uzivatelska_cinnost_faktury_id_seq', 34, true);


--
-- Name: faktury faktury_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.faktury
    ADD CONSTRAINT faktury_pkey PRIMARY KEY (id);


--
-- Name: klienti klienti_ico_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.klienti
    ADD CONSTRAINT klienti_ico_key UNIQUE (ico);


--
-- Name: klienti klienti_mail_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.klienti
    ADD CONSTRAINT klienti_mail_key UNIQUE (mail);


--
-- Name: klienti klienti_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.klienti
    ADD CONSTRAINT klienti_pkey PRIMARY KEY (id);


--
-- Name: klienti klienti_telefon_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.klienti
    ADD CONSTRAINT klienti_telefon_key UNIQUE (telefon);


--
-- Name: pozice pozice_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.pozice
    ADD CONSTRAINT pozice_pkey PRIMARY KEY (id);


--
-- Name: skoleni skoleni_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.skoleni
    ADD CONSTRAINT skoleni_pkey PRIMARY KEY (id);


--
-- Name: typ_zakazky typ_zakazky_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.typ_zakazky
    ADD CONSTRAINT typ_zakazky_pkey PRIMARY KEY (id);


--
-- Name: zakazky zakazky_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zakazky
    ADD CONSTRAINT zakazky_pkey PRIMARY KEY (id);


--
-- Name: zamestnanci zamestnanci_mail_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci
    ADD CONSTRAINT zamestnanci_mail_key UNIQUE (mail);


--
-- Name: zamestnanci zamestnanci_mobil_key; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci
    ADD CONSTRAINT zamestnanci_mobil_key UNIQUE (mobil);


--
-- Name: zamestnanci zamestnanci_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci
    ADD CONSTRAINT zamestnanci_pkey PRIMARY KEY (id);


--
-- Name: idx_zakazky_poznamky_fulltext; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX idx_zakazky_poznamky_fulltext ON public.zakazky USING gin (to_tsvector('public.czech'::regconfig, poznamky));


--
-- Name: faktury loggovani_cinnosti; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER loggovani_cinnosti AFTER INSERT OR DELETE OR UPDATE ON public.faktury FOR EACH ROW EXECUTE FUNCTION public.loggovani();


--
-- Name: faktury fk_faktury_typ_zakazky; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.faktury
    ADD CONSTRAINT fk_faktury_typ_zakazky FOREIGN KEY (id_typ) REFERENCES public.typ_zakazky(id);


--
-- Name: zamestnanci fk_pozice_zamestnanec; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci
    ADD CONSTRAINT fk_pozice_zamestnanec FOREIGN KEY (id_pozice) REFERENCES public.pozice(id);


--
-- Name: zamestnanci_skoleni fk_skoleni_zamestnanec; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci_skoleni
    ADD CONSTRAINT fk_skoleni_zamestnanec FOREIGN KEY (id_zamestnanec) REFERENCES public.zamestnanci(id);


--
-- Name: zakazky fk_zakazky_faktury; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zakazky
    ADD CONSTRAINT fk_zakazky_faktury FOREIGN KEY (id_faktury) REFERENCES public.faktury(id);


--
-- Name: zakazky fk_zakazky_klienti; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zakazky
    ADD CONSTRAINT fk_zakazky_klienti FOREIGN KEY (id_klient) REFERENCES public.klienti(id);


--
-- Name: zamestnanci_zakazky fk_zakazky_zamestnanci; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci_zakazky
    ADD CONSTRAINT fk_zakazky_zamestnanci FOREIGN KEY (id_zakazky) REFERENCES public.zakazky(id);


--
-- Name: zamestnanci_zakazky fk_zamestnanci_zakazky; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci_zakazky
    ADD CONSTRAINT fk_zamestnanci_zakazky FOREIGN KEY (id_zamestnance) REFERENCES public.zamestnanci(id);


--
-- Name: zamestnanci_skoleni fk_zamestnanec_skoleni; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.zamestnanci_skoleni
    ADD CONSTRAINT fk_zamestnanec_skoleni FOREIGN KEY (id_skoleni) REFERENCES public.skoleni(id);


--
-- Name: TABLE faktury; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.faktury TO "MarekKrál";
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.faktury TO "JaroslavaProcházková";


--
-- Name: TABLE faktury_po_splatnosti; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.faktury_po_splatnosti TO "MarekKrál";
GRANT SELECT ON TABLE public.faktury_po_splatnosti TO "JaroslavaProcházková";


--
-- Name: TABLE klienti; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.klienti TO "MarekKrál";
GRANT SELECT ON TABLE public.klienti TO "JaroslavaProcházková";
GRANT SELECT ON TABLE public.klienti TO "AlenaFiala";


--
-- Name: TABLE pozice; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.pozice TO "MarekKrál";
GRANT SELECT ON TABLE public.pozice TO "JaroslavaProcházková";


--
-- Name: TABLE zakazky; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.zakazky TO zamestnanci_ucty;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.zakazky TO "MarekKrál";
GRANT SELECT ON TABLE public.zakazky TO "JaroslavaProcházková";


--
-- Name: TABLE prehled_faktur; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.prehled_faktur TO "MarekKrál";
GRANT SELECT ON TABLE public.prehled_faktur TO "JaroslavaProcházková";


--
-- Name: TABLE skoleni; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT ON TABLE public.skoleni TO zamestnanci_ucty;
GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.skoleni TO "MarekKrál";
GRANT SELECT ON TABLE public.skoleni TO "JaroslavaProcházková";


--
-- Name: TABLE typ_zakazky; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.typ_zakazky TO "MarekKrál";
GRANT SELECT ON TABLE public.typ_zakazky TO "JaroslavaProcházková";


--
-- Name: TABLE uzivatelska_cinnost_faktury; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.uzivatelska_cinnost_faktury TO "MarekKrál";
GRANT SELECT ON TABLE public.uzivatelska_cinnost_faktury TO "JaroslavaProcházková";


--
-- Name: TABLE zamestnanci; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.zamestnanci TO "MarekKrál";
GRANT SELECT ON TABLE public.zamestnanci TO "JaroslavaProcházková";
GRANT SELECT ON TABLE public.zamestnanci TO "AlenaFiala";


--
-- Name: TABLE zamestnanci_skoleni; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.zamestnanci_skoleni TO "MarekKrál";
GRANT SELECT ON TABLE public.zamestnanci_skoleni TO "JaroslavaProcházková";


--
-- Name: TABLE zamestnanci_zakazky; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,INSERT,DELETE,UPDATE ON TABLE public.zamestnanci_zakazky TO "MarekKrál";
GRANT SELECT ON TABLE public.zamestnanci_zakazky TO "JaroslavaProcházková";


--
-- PostgreSQL database dump complete
--

