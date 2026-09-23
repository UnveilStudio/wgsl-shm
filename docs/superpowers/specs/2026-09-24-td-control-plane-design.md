# wgsl-shm — control plane per TouchDesigner: OSC, WebSocket, live coding

Data: 2026-09-24
Stato: design approvato, da implementare

## Intento

Oggi `wgsl-shm` è un generatore autonomo: si pilota a mano dal panel browser e
TouchDesigner sta a valle, consuma il frame e basta. L'obiettivo è ribaltare il
rapporto: **TD diventa il regista**. Continua a consumare il video (Spout), ma in
più guida i parametri e può spedire codice WGSL da compilare al volo.

Chi sta all'altro capo: **solo TouchDesigner**, sulla stessa macchina.
Non stiamo progettando un'API pubblica per consumatori arbitrari.

Successo = da un patch TD si muovono i parametri a rate video e si testa uno
shader nuovo senza toccare il filesystem né riavviare il processo, mentre il
video continua a uscire senza buchi.

## Decisioni prese (dal committente, non assunte)

| Decisione | Scelta |
|---|---|
| OSC e WS possono entrambi scrivere tutto? | **Sì**, sovrapposti, ultimo che scrive vince |
| Ritorno di stato verso TD? | **No.** TD manda e basta; da TD si guarda lo Spout, non i parametri |
| Conflitto UI vs sorgente esterna | **Lo slider si disabilita** nel panel quando il parametro arriva da fuori |
| WebSocket | Resta, non è opzionale |
| Live coding WGSL via WS | **Sì**, è il motivo per cui il WS è necessario |
| Reset parametri al cambio shader | **Da sistemare in questo giro** |

## Perché "ultimo che scrive vince" non è un problema

Con TD che pilota via OSC Out CHOP, i valori arrivano a ogni frame: su quei
parametri OSC vince *sempre*, non a volte. Questo **non si risolve nel codice** e
non va risolto: si decide nel patch TD scegliendo quali canali esportare. I
parametri che TD manda sono suoi; gli altri restano liberi per il panel.

Il codice fa solo una cosa a sostegno: traccia **da dove** è arrivata l'ultima
scrittura per parametro, e il panel usa quel dato per spegnere lo slider. La
semantica di scrittura resta identica.

## Architettura

Nessun nuovo meccanismo di sincronizzazione. `ShaderControlState` è già il
punto d'incontro (lock-protected) e il main loop fa già `snapshot_as_struct()`
una volta per frame: **quella fotografia per frame è già il punto di
serializzazione** che rende "ultimo che scrive vince" ben definito. Gli ingressi
nuovi sono adapter che chiamano `set_value`, come fa già il WS.

```
  TD ──OSC (60Hz, valori)───► osc_input.py ──┐
  TD ──WS  (comandi, WGSL)──► server.py   ───┼──► ShaderControlState ──► main loop ──► GPU
  browser ──WS (panel)──────► server.py   ───┘         (+ source per param)
```

### Componenti

**`control/osc_input.py`** (nuovo) — server `python-osc` in thread daemon, come
già fanno HTTP e WS. Un handler catch-all: indirizzo OSC = nome del parametro.
Chiama `state.set_value(name, value, source="osc")`.

**`control/server.py`** (esteso) — un messaggio in più (`shader_code`), risposta
di esito al mittente, `max_size` alzato, bind configurabile.

**`ShaderControlState`** — `set_value(name, value, source="panel")`; dizionario
`_sources[name] = (source, monotonic_ts)`; coda `pending_shader_code`.

**`control/panel.html`** (esteso) — disabilita gli slider pilotati da fuori.

**`wgsl_shm.py`** (esteso) — drena il codice pendente, compila, risponde; gestisce
la sospensione dell'hot-reload da file.

## Protocollo OSC

Indirizzo = **nome del parametro**, argomento singolo.

```
/scale      1.7
/warp       0.8
/color_mix  0.35
/col_a      0.1 0.1 0.5     (3 argomenti = colore)
```

Motivazione: l'OSC Out CHOP di TD usa il nome del canale come indirizzo OSC.
Chiami i canali come i parametri e funziona senza mapping da configurare.

Porta default **54323** (HTTP 54321, WS 54322, OSC 54323). Bind `127.0.0.1`.

Indirizzo sconosciuto: ignorato in silenzio. A 60 Hz un log per messaggio
sconosciuto inonderebbe stdout e rallenterebbe il render loop.

Valore fuori range: **clampato** al range dello schema corrente, non rifiutato.

## Protocollo WebSocket

Invariati: `{"name": ..., "value": ...}` e `{"type": "change_shader", "shader": ...}`.

Nuovo, in ingresso:

```json
{"type": "shader_code", "code": "<sorgente WGSL>"}
```

Nuovo, in uscita **al solo mittente**:

```json
{"type": "shader_result", "ok": true}
{"type": "shader_result", "ok": false, "error": "<messaggio del compilatore>"}
```

Questo è l'unico ritorno previsto, ed è diretto a chi ha mandato il codice, non
a TD come telemetria: senza, mandi codice rotto e vedi solo che l'immagine non
cambia, senza sapere se la colpa è tua, del socket o d'altro.

`max_size` passa da **16384 a 1 MB**: `raymarch.wgsl` sta sotto i 16 KB ma di
poco, e il limite non ha ragione di esistere per questo traffico.

## Live coding

Il pezzo difficile esiste già: `AMDGenerator.reload_shader()` accetta una
stringa e, se la compilazione fallisce, **tiene viva la pipeline precedente**.
È ciò che rende l'hot-reload da file sicuro in produzione. Il live coding lo
riusa cambiando solo la provenienza del codice.

Flusso: WS riceve `shader_code` → lo mette in coda → il main loop lo raccoglie
(come fa già con `pop_pending_shader`) → `gen.reload_shader(code)` → esito
rispedito al mittente.

La compilazione avviene **nel main loop**, mai nel thread WS: costruire una
pipeline wgpu da un altro thread mentre il loop renderizza non è sicuro.
Costo: una compilazione occupa un frame. Accettabile — succede quando scrivi
codice, non a ogni frame.

### Conflitto con l'hot-reload da file

Dopo un `shader_code`, il generator gira su codice che **non esiste su disco**,
ma `current_shader_path` punta ancora al `.wgsl`. Al primo cambio di mtime il
codice live verrebbe sovrascritto in silenzio.

Regola: il primo `shader_code` ricevuto **stacca il watcher del file**
(`live_mode = True`). Si riattacca quando si cambia shader dal panel
(`change_shader`), che è l'atto esplicito con cui si torna ai file su disco.
Il passaggio in live mode e il ritorno vengono loggati: è uno stato che cambia
il comportamento e deve essere visibile.

Il codice live **non viene salvato su disco**: è materiale da test. Se serve
tenerlo, si salva nel Text DAT lato TD.

## Preservazione dei parametri al cambio shader

Oggi `switch_schema()` fa `self._values = {}`: ogni cambio shader riporta tutto
ai default. Dal vivo è una mina — cambi shader e perdi la regolazione.

Nuovo comportamento: per ogni parametro del nuovo schema, se un valore con lo
stesso nome era già presente **lo si conserva**, altrimenti si prende il default.

**Il clamp non è opzionale.** I range differiscono realmente tra gli shader
(verificato sui 16 schemi):

| Parametro | Range distinti presenti |
|---|---|
| `scale` | da `(0.2, 6.0)` a `(1.0, 20.0)` |
| `warp` | `(0.0, 2.0)`, `(0.0, 3.0)`, `(0.2, 3.0)` |
| `octaves` | `(1, 4)`, `(1, 7)`, `(3, 12)` |
| `speed`, `color_mix` | uniformi |

Un valore conservato va quindi clampato **in entrambe le direzioni** nel range
del nuovo schema: `scale=18` è legittimo su uno shader e fuori scala su un
altro; `octaves=12` su uno shader che ne accetta 4 è un loop che non si vuole
in mezzo a un set; `octaves=2` verso uno schema con minimo 3 va alzato.

I colori (`col_a/b/c`) non hanno range: si conservano così come sono.

Un parametro assente dal nuovo schema resta nel dizionario ma non viene
serializzato (il layout uniform decide cosa entra nei byte): torna se si rientra
in uno shader che lo prevede.

## Lock degli slider

`_sources[name] = (source, ts)` aggiornato a ogni `set_value`.

Il panel considera un parametro **pilotato da fuori** se l'ultima scrittura ha
`source` in (`osc`, `ws`) ed è avvenuta **entro 2 secondi**. In quel caso lo
slider è disabilitato.

Il timeout è il punto importante: senza, staccare il patch TD lascerebbe la UI
morta senza modo di riprendere il controllo. Due secondi sono lunghi rispetto ai
16 ms di un OSC Out CHOP a 60 Hz (nessun lampeggio se TD sta mandando) e corti
abbastanza da non far aspettare quando TD smette.

Il panel apprende lo stato di lock da un messaggio periodico sul WS che il
server già usa per le notifiche (`schema_changed`); non serve un canale nuovo.

## Errori

| Caso | Comportamento |
|---|---|
| WGSL non compila | pipeline precedente viva, `shader_result` con l'errore al mittente, video mai interrotto |
| Indirizzo OSC sconosciuto | ignorato in silenzio (no log: 60 Hz) |
| Valore OSC di tipo sbagliato | ignorato, log una tantum per indirizzo |
| Valore fuori range | clampato |
| `python-osc` non installato | OSC disattivato con avviso chiaro; il resto funziona |
| Porta OSC occupata | errore esplicito all'avvio, non fallimento muto |
| Messaggio WS sopra 1 MB | chiuso dalla libreria; nessuna gestione speciale |

## Test

Il repo non ha suite di test (`AGENTS.md` lo dichiara). Questo lavoro introduce
logica pura e testabile senza GPU — la prima del progetto — e vale la pena
coprirla:

- **Clamp e preservazione al cambio shader**: puro `ShaderControlState`, nessuna GPU.
- **`_sources` e scadenza del lock**: temporale, con clock iniettabile.
- **Parsing OSC**: indirizzo → nome parametro, scalari e colori, casi sconosciuti.

Restano a verifica manuale, perché richiedono GPU e TD: il live coding
end-to-end, il pilotaggio OSC a 60 Hz, il lock degli slider nel browser.

Smoke esistente da non rompere (`AGENTS.md`): avvio headless, `--preview` a 720p,
hot-reload da file.

## Non-goals

- **Telemetria verso TD** — deciso: TD guarda lo Spout.
- **Salvataggio su disco del codice live** — resta nel Text DAT di TD.
- **Autenticazione / bind pubblico di default** — stessa macchina, `127.0.0.1`;
  `--bind` esiste ma è una scelta esplicita di chi lo usa.
- **Registrazione e replay di una performance** — l'architettura ad adapter non
  la preclude (un bus di comandi si infilerebbe tra adapter e stato senza
  toccare gli adapter), ma oggi non serve.
- **Uniform layout per-shader** — `UNIFORM_LAYOUT` resta fisso e condiviso dai 16
  shader. È un limite noto e sentito, ma è un lavoro a sé: tocca schema,
  panel, WGSL e serializzazione insieme.
- **MIDI, preset, LFO, BPM** — separati.

## Dipendenze

`python-osc` (MIT, puro Python, nessun binario) in `requirements.txt`.
Assente = OSC disattivato con avviso, il resto funziona.

## Superficie CLI

```
--osc-port N     porta OSC in ingresso (default 54323)
--no-osc         non aprire l'ingresso OSC
--bind ADDR      indirizzo di bind per HTTP/WS/OSC (default 127.0.0.1)
```
