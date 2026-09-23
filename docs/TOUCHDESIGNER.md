# Pilotare wgsl-shm da TouchDesigner

`wgsl-shm` esce in Spout e si fa guidare da TD su due canali: **OSC** per i
parametri (flusso continuo) e **WebSocket** per i comandi e per spedire codice
WGSL da compilare al volo.

Avvio lato Python:

```bash
python wgsl_shm.py --out spout --spout-name wgsl-shm
```

Porte aperte: HTTP `54321`, WebSocket `54322`, OSC `54323`.

---

## 1. Il video — Spout In TOP

Un **Spout In TOP**, `Sender Name = wgsl-shm`. Fine: è il frame a piena
risoluzione, già sulla GPU.

---

## 2. I parametri — OSC Out CHOP

`wgsl-shm` usa **il nome del canale come indirizzo OSC**, quindi non c'è nessun
mapping da configurare: chiama i canali come i parametri e funziona.

1. Un **Constant CHOP** (o qualunque cosa produca i valori) con i canali
   chiamati esattamente come i parametri dello shader: `scale`, `warp`,
   `speed`, `color_mix`, `octaves`.
2. Un **OSC Out CHOP** a valle, `Network Address = 127.0.0.1`,
   `Network Port = 54323`.

I colori vogliono tre valori sullo stesso indirizzo. Il modo più semplice è un
**Script CHOP** o un breve pezzo di Python che manda `/col_a 0.1 0.1 0.5`.

### Chi comanda cosa

L'OSC Out CHOP manda i suoi canali **a ogni frame**. Con "ultimo che scrive
vince" questo significa che i parametri che esporti sono **tuoi**: il panel
browser non riesce a muoverli, e infatti li mostra con lo slider spento.

Quindi la regola è: **esporta solo i canali che vuoi guidare da TD.** Quelli che
non mandi restano liberi per il panel. È così che si decide la divisione dei
ruoli — nel patch, non in un file di configurazione.

Quando smetti di mandare un parametro, il panel se lo riprende dopo **2
secondi**.

---

## 3. Comandi e live coding — WebSocket DAT

Un **WebSocket DAT**, `Network Address = 127.0.0.1`, `Network Port = 54322`,
`Active = On`.

### Cambiare shader

```python
import json
op('websocket1').sendText(json.dumps({
    'type': 'change_shader',
    'shader': 'nebula',          # nome senza estensione, da shaders/
}))
```

Cambiare shader **conserva i parametri** che hai impostato (clampati nel range
del nuovo shader), e riporta il sistema a leggere i file su disco se eri in
live coding.

### Spedire uno shader — live coding

Metti il WGSL in un **Text DAT** (chiamiamolo `wgsl1`) e spediscilo:

```python
import json
code = op('wgsl1').text
op('websocket1').sendText(json.dumps({'type': 'shader_code', 'code': code}))
```

Il risultato arriva nel callback DAT del WebSocket:

```python
def onReceiveText(dat, rowIndex, message):
    import json
    m = json.loads(message)
    if m.get('type') == 'shader_result':
        if m['ok']:
            print('shader OK')
        else:
            print(m['error'])       # riga, colonna e caret dal compilatore
    return
```

**Se il codice non compila il video non si ferma**: resta in onda lo shader
precedente e ti arriva l'errore. Puoi sbagliare quanto vuoi mentre giri.

L'errore è quello vero di wgpu, con posizione:

```
Shader '' parsing error: expected global item ...
  ┌─ wgsl:1:1
  │
1 │ questo non e' WGSL valido
  │ ^^^^^^ expected global item
```

### Il contratto dello shader

Uno shader spedito deve rispettare lo stesso contratto di quelli in `shaders/`:

- `@group(0) @binding(0)` — uniform `Uni`, 80 byte
- `@group(0) @binding(1)` — `texture_storage_2d<rgba8unorm, write>`
- entry point `main`, `@compute @workgroup_size(16, 16)`

Il modo più rapido è partire da `shaders/plasma.wgsl` e cambiare solo il corpo
di `main`. Un minimo che compila:

```wgsl
struct Uni {
    time:f32, width:f32, height:f32, scale:f32,
    warp:f32, speed:f32, color_mix:f32, octaves_f:f32,
    col_a:vec4<f32>, col_b:vec4<f32>, col_c:vec4<f32>,
};
@group(0) @binding(0) var<uniform> uni : Uni;
@group(0) @binding(1) var out_tex : texture_storage_2d<rgba8unorm, write>;

@compute @workgroup_size(16, 16)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let uv = vec2<f32>(gid.xy) / vec2<f32>(uni.width, uni.height);
    let c  = 0.5 + 0.5 * sin(uni.time * uni.speed + uv.x * uni.scale * 10.0);
    textureStore(out_tex, vec2<i32>(gid.xy), vec4<f32>(c, uv.y, 1.0 - c, 1.0));
}
```

Il codice spedito **non viene salvato su disco**: vive nel processo finché non
ne mandi altro o cambi shader. Se ti piace, tienilo tu nel Text DAT.

---

## Riferimento rapido

| Cosa | Dove | Come |
|---|---|---|
| Video | Spout In TOP | `Sender Name = wgsl-shm` |
| Parametri | OSC Out CHOP → `127.0.0.1:54323` | canale `scale` → `/scale` |
| Colori | OSC, 3 argomenti | `/col_a 0.1 0.1 0.5` |
| Cambio shader | WebSocket DAT → `:54322` | `{"type":"change_shader","shader":"nebula"}` |
| Live coding | WebSocket DAT → `:54322` | `{"type":"shader_code","code":"..."}` |
| Esito compilazione | callback `onReceiveText` | `{"type":"shader_result","ok":...}` |

`wgsl-shm` non rimanda mai lo stato dei parametri a TD: da TD guardi il video,
i parametri li conosci già perché sei tu a mandarli.
