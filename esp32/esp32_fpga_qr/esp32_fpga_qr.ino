// ===================================================================
// esp32_fpga_qr.ino  -  Puente Wi-Fi <-> UART entre PC/iPhone y la FPGA
// Placa: ESP32 WROOM-32 (Arduino IDE: "ESP32 Dev Module")
// Solo usa bibliotecas incluidas en el paquete esp32 de Espressif.
//
//   PC (navegador) --POST /api/encrypt--> ESP32 --'E'+16--> FPGA
//                                         ESP32 <--'C'+60-- FPGA (QR en VGA)
//   iPhone (Atajo) --POST /api/decrypt--> ESP32 --'D'+60--> FPGA
//                                         ESP32 <--'P'+estado+16-- FPGA
//   La pagina de la PC muestra todos los eventos (se actualiza sola).
//   Opcional: el boton "Generar QR aqui" dibuja el mismo QR en la pagina
//   (JavaScript en el navegador), por si no hay monitor VGA.
//
// Conexion (3.3 V en ambos lados, tierra comun):
//   FPGA UART_TX -> GPIO16 (RX2)     FPGA UART_RX <- GPIO17 (TX2)
//   GND -- GND
// Protocolo: ver LEEME_top.txt (115200 8N1).
// ===================================================================

#include <WiFi.h>
#include <WebServer.h>
#include <ESPmDNS.h>

// ------------------------- CONFIGURACION ---------------------------
// Red de tu casa/escuela. Si WIFI_SSID queda vacio, o no conecta en
// 15 s, la ESP32 crea su propia red con AP_SSID / AP_PASS.
const char* WIFI_SSID = "";
const char* WIFI_PASS = "";

const char* AP_SSID   = "FPGA-QR";
const char* AP_PASS   = "fpga1234";      // minimo 8 caracteres
const char* HOSTNAME  = "fpga-qr";       // http://fpga-qr.local

const int      FPGA_RX_PIN = 16;         // RX2  <- FPGA UART_TX
const int      FPGA_TX_PIN = 17;         // TX2  -> FPGA UART_RX
const uint32_t FPGA_BAUD   = 115200;
const uint32_t REPLY_TIMEOUT_MS = 1000;  // la FPGA contesta en ~7 ms
// -------------------------------------------------------------------

HardwareSerial& fpga = Serial2;
WebServer server(80);

// ----------------------- Registro de eventos -----------------------
struct Event {
  uint32_t id;
  uint32_t ms;
  String   kind;   // cifrado, boton, correcto, rechazado, error
  String   text;
};
const int MAX_EVENTS = 30;
Event    events[MAX_EVENTS];
uint32_t nextEventId = 1;

void addEvent(const String& kind, const String& text) {
  Event& e = events[(nextEventId - 1) % MAX_EVENTS];
  e.id   = nextEventId++;
  e.ms   = millis();
  e.kind = kind;
  e.text = text;
  Serial.printf("[%lu] %s: %s\n", (unsigned long)e.ms, kind.c_str(), text.c_str());
}

String jsonEscape(const String& s) {
  String out;
  out.reserve(s.length() + 8);
  for (size_t i = 0; i < s.length(); i++) {
    uint8_t c = (uint8_t)s[i];
    if (c == '"')       out += "\\\"";
    else if (c == '\\') out += "\\\\";
    else if (c < 0x20) {
      char buf[8];
      snprintf(buf, sizeof(buf), "\\u%04x", c);
      out += buf;
    } else out += (char)c;
  }
  return out;
}

// Bytes del mensaje descifrado -> texto legible (sin espacios finales)
String plainToString(const uint8_t* p, size_t n) {
  while (n > 0 && (p[n - 1] == ' ' || p[n - 1] == 0)) n--;
  String s;
  for (size_t i = 0; i < n; i++) {
    if (p[i] >= 0x20 && p[i] != 0x7f) s += (char)p[i];
    else { char b[6]; snprintf(b, sizeof(b), "\\x%02X", p[i]); s += b; }
  }
  return s;
}

// --------------------------- UART FPGA -----------------------------
bool readExact(uint8_t* buf, size_t n, uint32_t timeoutMs) {
  uint32_t t0 = millis();
  size_t got = 0;
  while (got < n) {
    if (fpga.available()) {
      buf[got++] = (uint8_t)fpga.read();
    } else if (millis() - t0 > timeoutMs) {
      return false;
    } else {
      delay(1);
    }
  }
  return true;
}

// Lee una trama completa si empieza con 'C' o 'P'. Devuelve su tipo, o 0.
// 'C': payload = 60 bytes Base64.  'P': payload = estado + 16 bytes.
char readFrame(uint8_t* payload, uint32_t timeoutMs) {
  uint32_t t0 = millis();
  while (millis() - t0 <= timeoutMs) {
    if (!fpga.available()) { delay(1); continue; }
    int b = fpga.read();
    if (b == 'C') return readExact(payload, 60, 100) ? 'C' : 0;
    if (b == 'P') return readExact(payload, 17, 100) ? 'P' : 0;
    // Otro byte: se descarta (ruido o resto de una trama incompleta).
  }
  return 0;
}

// Tramas que llegan sin que la ESP32 las pida (KEY1 en la placa).
void logUnsolicited(char type, const uint8_t* payload) {
  if (type == 'C') {
    addEvent("boton", "QR generado con KEY1: " + String((const char*)payload).substring(0, 60));
  } else if (type == 'P') {
    addEvent("error", "Respuesta P inesperada");
  }
}

void pollFpga() {
  uint8_t payload[61];
  while (fpga.available()) {
    memset(payload, 0, sizeof(payload));
    char t = readFrame(payload, 0);
    if (t) logUnsolicited(t, payload);
  }
}

// Espera una respuesta de tipo 'want'; registra otras que lleguen antes.
bool waitReply(char want, uint8_t* payload) {
  uint32_t t0 = millis();
  for (;;) {
    uint32_t elapsed = millis() - t0;
    if (elapsed >= REPLY_TIMEOUT_MS) break;
    memset(payload, 0, 61);
    char t = readFrame(payload, REPLY_TIMEOUT_MS - elapsed);
    if (t == want) return true;
    if (t) logUnsolicited(t, payload);
  }
  return false;
}

// --------------------------- Cuerpo HTTP ---------------------------
// Acepta: texto plano, JSON {"text":"..."} (Atajos de iPhone) o
// formulario text=... . Devuelve el texto tal cual llego.
String extractJsonText(const String& body) {
  int k = body.indexOf("\"text\"");
  if (k < 0) return "";
  int colon = body.indexOf(':', k + 6);
  if (colon < 0) return "";
  int q = body.indexOf('"', colon + 1);
  if (q < 0) return "";
  String out;
  for (int i = q + 1; i < (int)body.length(); i++) {
    char c = body[i];
    if (c == '"') break;
    if (c == '\\' && i + 1 < (int)body.length()) {
      char n = body[++i];
      if (n == 'n') out += '\n';
      else if (n == 't') out += '\t';
      else if (n == 'r') out += '\r';
      else if (n == 'u' && i + 4 < (int)body.length()) {
        out += (char)strtol(body.substring(i + 1, i + 5).c_str(), nullptr, 16);
        i += 4;
      } else out += n;          // \" \\ \/  (iOS escribe '/' como "\/")
    } else out += c;
  }
  return out;
}

String requestText() {
  if (server.hasArg("plain")) {
    String body = server.arg("plain");
    String trimmed = body; trimmed.trim();
    if (trimmed.startsWith("{")) return extractJsonText(trimmed);
    return body;
  }
  if (server.hasArg("text")) return server.arg("text");
  return "";
}

// ---------------------------- Handlers -----------------------------
void sendJson(int code, const String& json) {
  server.send(code, "application/json; charset=utf-8", json);
}

void handleEncrypt() {
  String msg = requestText();
  if (msg.length() == 0) {
    sendJson(400, "{\"ok\":false,\"error\":\"Mensaje vacio\"}");
    return;
  }
  if (msg.length() > 16) {
    sendJson(400, "{\"ok\":false,\"error\":\"Maximo 16 bytes (los acentos ocupan 2)\"}");
    return;
  }
  uint8_t frame[17];
  frame[0] = 'E';
  for (int i = 0; i < 16; i++)
    frame[1 + i] = (i < (int)msg.length()) ? (uint8_t)msg[i] : ' ';

  pollFpga();                       // vaciar tramas pendientes
  fpga.write(frame, sizeof(frame));

  uint8_t payload[61];
  if (!waitReply('C', payload)) {
    addEvent("error", "La FPGA no respondio al cifrar \"" + msg + "\"");
    sendJson(502, "{\"ok\":false,\"error\":\"La FPGA no respondio\"}");
    return;
  }
  payload[60] = 0;
  String b64 = String((const char*)payload);
  addEvent("cifrado", "\"" + msg + "\" -> QR en pantalla: " + b64);
  sendJson(200, "{\"ok\":true,\"base64\":\"" + jsonEscape(b64) + "\"}");
}

void handleDecrypt() {
  String raw = requestText();
  // Un formulario convierte '+' en espacio; Base64 no tiene espacios,
  // asi que se recupera. Saltos de linea y tabuladores se eliminan.
  String text;
  for (size_t i = 0; i < raw.length(); i++) {
    char c = raw[i];
    if (c == ' ') text += '+';
    else if (c != '\r' && c != '\n' && c != '\t') text += c;
  }
  if (text.length() != 60) {
    String err = "Se esperaban 60 caracteres y llegaron " + String(text.length());
    addEvent("error", err);
    server.send(400, "text/plain; charset=utf-8", "ERROR: " + err);
    return;
  }

  uint8_t frame[61];
  frame[0] = 'D';
  memcpy(frame + 1, text.c_str(), 60);

  pollFpga();
  fpga.write(frame, sizeof(frame));

  uint8_t payload[61];
  if (!waitReply('P', payload)) {
    addEvent("error", "La FPGA no respondio al descifrar");
    server.send(502, "text/plain; charset=utf-8", "ERROR: la FPGA no respondio");
    return;
  }

  String result;
  char status = (char)payload[0];
  if (status == 'K') {
    String m = plainToString(payload + 1, 16);
    result = "OK: " + m;
    addEvent("correcto", "Descifrado: \"" + m + "\"");
  } else if (status == 'T') {
    result = "RECHAZADO: etiqueta GCM incorrecta (texto alterado o clave distinta)";
    addEvent("rechazado", "Etiqueta GCM incorrecta: " + text);
  } else if (status == 'B') {
    result = "RECHAZADO: Base64 invalido";
    addEvent("rechazado", "Base64 invalido: " + text);
  } else {
    result = "ERROR: estado desconocido de la FPGA";
    addEvent("error", result);
  }
  // Texto plano para que el Atajo del iPhone lo muestre directamente.
  server.send(200, "text/plain; charset=utf-8", result);
}

void handleEvents() {
  uint32_t since = server.hasArg("since") ? strtoul(server.arg("since").c_str(), nullptr, 10) : 0;
  String json = "[";
  bool first = true;
  uint32_t oldest = (nextEventId > MAX_EVENTS) ? nextEventId - MAX_EVENTS : 1;
  for (uint32_t id = max(oldest, since + 1); id < nextEventId; id++) {
    const Event& e = events[(id - 1) % MAX_EVENTS];
    if (!first) json += ",";
    first = false;
    json += "{\"id\":" + String(e.id) + ",\"ms\":" + String(e.ms) +
            ",\"kind\":\"" + jsonEscape(e.kind) + "\",\"text\":\"" + jsonEscape(e.text) + "\"}";
  }
  json += "]";
  sendJson(200, json);
}

// ------------------------------ Pagina -----------------------------
const char PAGE[] PROGMEM = R"HTML(<!doctype html>
<html lang="es"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FPGA QR</title>
<style>
 body{font-family:system-ui,sans-serif;max-width:760px;margin:0 auto;padding:16px;background:#f4f5f7;color:#1c1e21}
 h1{font-size:1.4rem;margin:.2rem 0 1rem}
 section{background:#fff;border-radius:10px;padding:14px 16px;margin-bottom:14px;box-shadow:0 1px 3px #0001}
 h2{font-size:1rem;margin:0 0 .6rem}
 input,textarea{width:100%;box-sizing:border-box;font:inherit;padding:8px;border:1px solid #ccd;border-radius:6px}
 textarea{font-family:ui-monospace,monospace;font-size:.85rem;height:3.4em}
 button{margin-top:8px;padding:8px 16px;font:inherit;border:0;border-radius:6px;background:#2563eb;color:#fff;cursor:pointer}
 button:disabled{opacity:.5}
 .out{margin-top:8px;font-family:ui-monospace,monospace;font-size:.85rem;word-break:break-all}
 .small{color:#667;font-size:.8rem}
 ul{list-style:none;padding:0;margin:0}
 li{padding:8px 0;border-top:1px solid #eee;font-size:.9rem;word-break:break-word}
 li:first-child{border-top:0}
 .tag{display:inline-block;min-width:78px;font-size:.75rem;font-weight:600;padding:2px 6px;border-radius:4px;margin-right:6px;text-align:center}
 .cifrado,.boton{background:#dbeafe;color:#1e40af}.correcto{background:#dcfce7;color:#166534}
 .rechazado,.error{background:#fee2e2;color:#991b1b}
</style></head><body>
<h1>FPGA: AES-GCM + QR</h1>
<section><h2>1. Cifrar en la FPGA</h2>
 <input id="msg" maxlength="16" placeholder="Hasta 16 caracteres">
 <div class="small"><span id="cnt">0</span>/16 bytes</div>
 <button id="enc">Cifrar y mostrar QR</button>
 <div id="encOut" class="out"></div></section>
<section><h2>2. Descifrar en la FPGA (opcional, sin iPhone)</h2>
 <textarea id="b64" placeholder="Texto Base64 de 60 caracteres"></textarea>
 <button id="dec">Descifrar</button>
 <div id="decOut" class="out"></div></section>
<section><h2>3. Ver el QR en esta pagina (en vez de la pantalla VGA)</h2>
 <div class="small">Usa el Base64 del cuadro de arriba (se llena solo al cifrar).</div>
 <button id="qrBtn">Generar QR aqui</button>
 <div id="qrOut" class="out"></div>
 <canvas id="qr" width="328" height="328" style="display:none;margin-top:8px;image-rendering:pixelated"></canvas>
 <div><a id="qrDl" download="qr_fpga.png" style="display:none">Descargar PNG</a></div></section>
<section><h2>Resultados</h2>
 <div class="small">Se actualiza solo: aqui aparece lo que envia el iPhone.</div>
 <ul id="ev"></ul></section>
<script>
const $=id=>document.getElementById(id);
const enc=new TextEncoder();
$('msg').addEventListener('input',()=>{$('cnt').textContent=enc.encode($('msg').value).length;});
async function post(url,body){
  const r=await fetch(url,{method:'POST',headers:{'Content-Type':'text/plain'},body});
  return {ok:r.ok,text:await r.text()};
}
$('enc').onclick=async()=>{
  const m=$('msg').value;
  if(enc.encode(m).length>16){$('encOut').textContent='Maximo 16 bytes';return;}
  $('enc').disabled=true;
  try{const r=await post('/api/encrypt',m);const j=JSON.parse(r.text);
      $('encOut').textContent=j.ok?('QR en pantalla. Base64: '+j.base64):('Error: '+j.error);
      if(j.ok)$('b64').value=j.base64;}
  catch(e){$('encOut').textContent='Error: '+e;}
  $('enc').disabled=false;
};
$('dec').onclick=async()=>{
  $('dec').disabled=true;
  try{const r=await post('/api/decrypt',$('b64').value.trim());$('decOut').textContent=r.text;}
  catch(e){$('decOut').textContent='Error: '+e;}
  $('dec').disabled=false;
};
// QR version 4, nivel M, modo byte (hasta 62 bytes). Mismo perfil y mismo
// algoritmo que qr_generator.v: da la misma matriz y la misma mascara.
function qrMatrix(bytes){
  const N=33,DATA=64,ECC=18;
  if(bytes.length>62)throw 'Maximo 62 bytes para QR version 4-M';
  // 1. Bits: modo byte (0100) + longitud (8 bits) + datos + terminador + relleno
  const bits=[];const put=(v,n)=>{for(let i=n-1;i>=0;i--)bits.push((v>>>i)&1);};
  put(4,4);put(bytes.length,8);for(const b of bytes)put(b,8);
  put(0,Math.min(4,DATA*8-bits.length));while(bits.length%8)bits.push(0);
  const data=[];for(let i=0;i<bits.length;i+=8){let v=0;for(let j=0;j<8;j++)v=(v<<1)|bits[i+j];data.push(v);}
  for(let p=0xEC;data.length<DATA;p^=0xEC^0x11)data.push(p);
  // 2. Reed-Solomon en GF(256), polinomio 0x11D: 2 bloques de 32 datos + 18 ECC
  const mul=(x,y)=>{let z=0;for(let i=7;i>=0;i--){z=(z<<1)^((z>>>7)*0x11D);z^=((y>>>i)&1)*x;}return z;};
  const gen=new Array(ECC).fill(0);gen[ECC-1]=1;
  for(let i=0,r=1;i<ECC;i++,r=mul(r,2))for(let j=0;j<ECC;j++){gen[j]=mul(gen[j],r);if(j+1<ECC)gen[j]^=gen[j+1];}
  const rs=blk=>{const res=new Array(ECC).fill(0);for(const b of blk){const f=b^res.shift();res.push(0);for(let i=0;i<ECC;i++)res[i]^=mul(gen[i],f);}return res;};
  const b0=data.slice(0,32),b1=data.slice(32),e0=rs(b0),e1=rs(b1),cw=[];
  for(let i=0;i<32;i++)cw.push(b0[i],b1[i]);for(let i=0;i<ECC;i++)cw.push(e0[i],e1[i]);
  // 3. Patrones fijos (m[fila][col]); fn marca los modulos que no son datos
  const m=[],fn=[];for(let y=0;y<N;y++){m.push(new Array(N).fill(0));fn.push(new Array(N).fill(false));}
  const set=(x,y,v)=>{m[y][x]=v?1:0;fn[y][x]=true;};
  for(let i=0;i<N;i++){set(6,i,i%2==0);set(i,6,i%2==0);}
  for(const[cx,cy]of[[3,3],[N-4,3],[3,N-4]])
    for(let dy=-4;dy<=4;dy++)for(let dx=-4;dx<=4;dx++){const x=cx+dx,y=cy+dy,d=Math.max(Math.abs(dx),Math.abs(dy));
      if(x>=0&&x<N&&y>=0&&y<N)set(x,y,d!=2&&d!=4);}
  for(let dy=-2;dy<=2;dy++)for(let dx=-2;dx<=2;dx++)set(26+dx,26+dy,Math.max(Math.abs(dx),Math.abs(dy))!=1);
  const format=mask=>{const d=mask;let r=d;for(let i=0;i<10;i++)r=(r<<1)^((r>>>9)*0x537);
    const f=((d<<10)|r)^0x5412,g=i=>(f>>>i)&1;
    for(let i=0;i<=5;i++)set(8,i,g(i));set(8,7,g(6));set(8,8,g(7));set(7,8,g(8));
    for(let i=9;i<15;i++)set(14-i,8,g(i));for(let i=0;i<8;i++)set(N-1-i,8,g(i));
    for(let i=8;i<15;i++)set(8,N-15+i,g(i));set(8,N-8,1);};
  format(0);
  // 4. Datos en zigzag desde la esquina inferior derecha (se salta la columna 6)
  let k=0;
  for(let r=N-1;r>=1;r-=2){if(r==6)r=5;
    for(let v=0;v<N;v++)for(let j=0;j<2;j++){const x=r-j,y=((r+1)&2)==0?N-1-v:v;
      if(!fn[y][x]&&k<cw.length*8){m[y][x]=(cw[k>>>3]>>>(7-(k&7)))&1;k++;}}}
  // 5. Mascara: se prueban las 8 y se queda la de menor penalizacion
  const cond=(t,x,y)=>[(x+y)%2,y%2,x%3,(x+y)%3,(Math.floor(x/3)+Math.floor(y/2))%2,
    x*y%2+x*y%3,(x*y%2+x*y%3)%2,((x+y)%2+x*y%3)%2][t]==0;
  const apply=t=>{for(let y=0;y<N;y++)for(let x=0;x<N;x++)if(!fn[y][x]&&cond(t,x,y))m[y][x]^=1;};
  const penalty=()=>{let s=0;
    const add=(len,h)=>{if(h[0]==0)len+=N;h.pop();h.unshift(len);};
    const cnt=h=>{const n=h[1],c=n>0&&h[2]==n&&h[3]==n*3&&h[4]==n&&h[5]==n;
      return(c&&h[0]>=n*4&&h[6]>=n?1:0)+(c&&h[6]>=n*4&&h[0]>=n?1:0);};
    for(let p=0;p<2;p++)for(let a=0;a<N;a++){let col=0,run=0;const h=[0,0,0,0,0,0,0];
      for(let b=0;b<N;b++){const v=p?m[b][a]:m[a][b];
        if(v==col){run++;if(run==5)s+=3;else if(run>5)s++;}
        else{add(run,h);if(!col)s+=cnt(h)*40;col=v;run=1;}}
      if(col){add(run,h);run=0;}run+=N;add(run,h);s+=cnt(h)*40;}
    let dark=0;
    for(let y=0;y<N;y++)for(let x=0;x<N;x++){dark+=m[y][x];
      if(x<N-1&&y<N-1&&m[y][x]==m[y][x+1]&&m[y][x]==m[y+1][x]&&m[y][x]==m[y+1][x+1])s+=3;}
    return s+(Math.ceil(Math.abs(dark*20-N*N*10)/(N*N))-1)*10;};
  let best=0,bestP=1e9;
  for(let t=0;t<8;t++){apply(t);format(t);const p=penalty();if(p<bestP){bestP=p;best=t;}apply(t);}
  apply(best);format(best);
  return {m:m,mask:best};
}
// Dibuja la matriz con margen blanco de 4 modulos, 8 pixeles por modulo
$('qrBtn').onclick=()=>{
  const s=$('b64').value.trim(),c=$('qr');
  if(!s){$('qrOut').textContent='Primero cifra un mensaje (o pega un Base64 arriba)';return;}
  try{
    const q=qrMatrix(enc.encode(s)),S=8,Q=4,g=c.getContext('2d');
    c.width=c.height=(33+2*Q)*S;
    g.fillStyle='#fff';g.fillRect(0,0,c.width,c.height);g.fillStyle='#000';
    for(let y=0;y<33;y++)for(let x=0;x<33;x++)if(q.m[y][x])g.fillRect((x+Q)*S,(y+Q)*S,S,S);
    c.style.display='block';
    $('qrDl').href=c.toDataURL('image/png');$('qrDl').style.display='inline-block';
    $('qrOut').textContent='QR version 4-M, mascara '+q.mask+' ('+s.length+' caracteres)';
  }catch(e){$('qrOut').textContent='Error: '+e;}
};
let last=0;
async function poll(){
  try{const r=await fetch('/api/events?since='+last);const list=await r.json();
    for(const e of list){last=e.id;const li=document.createElement('li');
      const t=document.createElement('span');t.className='tag '+e.kind;t.textContent=e.kind;
      li.appendChild(t);li.appendChild(document.createTextNode(e.text));
      $('ev').prepend(li);}
  }catch(e){}
  setTimeout(poll,1000);
}
poll();
</script></body></html>)HTML";

void handleRoot() {
  server.send_P(200, "text/html; charset=utf-8", PAGE);
}

// ------------------------------ Setup ------------------------------
void startWifi() {
  bool connected = false;
  if (strlen(WIFI_SSID) > 0) {
    WiFi.mode(WIFI_STA);
    WiFi.setHostname(HOSTNAME);
    WiFi.begin(WIFI_SSID, WIFI_PASS);
    Serial.printf("Conectando a %s", WIFI_SSID);
    uint32_t t0 = millis();
    while (WiFi.status() != WL_CONNECTED && millis() - t0 < 15000) {
      delay(500);
      Serial.print(".");
    }
    Serial.println();
    connected = (WiFi.status() == WL_CONNECTED);
  }
  if (connected) {
    Serial.print("Conectado. Abrir en la PC: http://");
    Serial.println(WiFi.localIP());
  } else {
    WiFi.mode(WIFI_AP);
    WiFi.softAP(AP_SSID, AP_PASS);
    Serial.printf("Red propia \"%s\" (clave %s). Abrir: http://", AP_SSID, AP_PASS);
    Serial.println(WiFi.softAPIP());
  }
  if (MDNS.begin(HOSTNAME)) {
    MDNS.addService("http", "tcp", 80);
    Serial.printf("Tambien: http://%s.local\n", HOSTNAME);
  }
}

void setup() {
  Serial.begin(115200);
  delay(200);
  fpga.begin(FPGA_BAUD, SERIAL_8N1, FPGA_RX_PIN, FPGA_TX_PIN);

  startWifi();

  server.on("/", HTTP_GET, handleRoot);
  server.on("/api/encrypt", HTTP_POST, handleEncrypt);
  server.on("/api/decrypt", HTTP_POST, handleDecrypt);
  server.on("/api/events", HTTP_GET, handleEvents);
  server.onNotFound([]() { server.send(404, "text/plain", "No encontrado"); });
  server.begin();

  addEvent("inicio", "ESP32 lista");
}

void loop() {
  server.handleClient();
  pollFpga();
  delay(2);
}
