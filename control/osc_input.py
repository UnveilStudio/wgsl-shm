"""
control/osc_input.py — ingresso OSC per i parametri dello shader.

Pensato per essere pilotato da TouchDesigner: l'OSC Out CHOP manda il nome del
canale come indirizzo OSC, quindi chiamando i canali come i parametri
(`scale`, `warp`, `col_a`, ...) non c'e' nessun mapping da configurare.

    /scale      1.7
    /warp       0.8
    /col_a      0.1 0.1 0.5      (3 argomenti = colore)

Gira in un thread daemon come HTTP e WS. I valori finiscono nello stesso
`ShaderControlState` che usa il panel: convivono con "ultimo che scrive vince",
e il panel spegne gli slider dei parametri che arrivano da qui.

Uso:
    stop = start_osc(state, port=54323)   # None se python-osc non c'e'
"""
import threading


OSC_PORT = 54323


def _coerce(args):
    """Argomenti OSC -> valore per lo stato. None se non utilizzabile."""
    nums = [a for a in args if isinstance(a, (int, float)) and not isinstance(a, bool)]
    if len(nums) != len(args) or not nums:
        return None
    if len(nums) == 1:
        return float(nums[0])
    if len(nums) == 3:              # colore
        return [float(v) for v in nums]
    return None


def make_dispatcher(state, on_unknown=None):
    """Dispatcher OSC che scrive in `state`. Separato per essere testabile."""
    from pythonosc.dispatcher import Dispatcher

    known = set()
    try:
        known = {u["name"] for u in state.get_schema()["uniforms"]}
    except Exception:
        pass
    warned: set = set()

    def handle(address, *args):
        name = address.lstrip("/")
        value = _coerce(args)
        if value is None:
            # Un log per indirizzo, non per messaggio: a 60 Hz inonderebbe
            # stdout e rallenterebbe il render loop.
            if name not in warned:
                warned.add(name)
                print(f"[osc] '{address}': argomenti non utilizzabili {args!r}")
            return
        if known and name not in known:
            if on_unknown is not None:
                on_unknown(name)
            return                       # silenzio: indirizzo sconosciuto
        state.set_value(name, value, source="osc")

    d = Dispatcher()
    d.set_default_handler(handle)
    return d


def start_osc(state, port: int = OSC_PORT, bind: str = "127.0.0.1"):
    """Avvia il server OSC in un thread daemon.

    Ritorna l'oggetto server, o None se `python-osc` non e' installato — in
    quel caso il resto del programma funziona senza OSC.
    Se la porta e' occupata solleva: e' un errore che va visto, non ingoiato.
    """
    try:
        from pythonosc.osc_server import ThreadingOSCUDPServer
    except ImportError:
        print("[osc] python-osc non installato: ingresso OSC disattivato "
              "(pip install python-osc)")
        return None

    dispatcher = make_dispatcher(state)
    server = ThreadingOSCUDPServer((bind, port), dispatcher)
    t = threading.Thread(target=server.serve_forever, daemon=True, name="osc-in")
    t.start()
    print(f"[osc] in    udp://{bind}:{port}/  (indirizzo = nome parametro)")
    return server
