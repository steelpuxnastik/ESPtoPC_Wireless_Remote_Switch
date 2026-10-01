/*
 * ESP-01: удалённое управление кнопками Power/Reset ПК через HTTP.
 * -----------------------------------------------------------------
 * GPIO1 (TX)  -> затвор Q1 (Power button). LOW = кнопка нажата, HIGH = отпущена.
 * GPIO3 (RX)  -> затвор Q3 (Reset button). LOW = кнопка нажата, HIGH = отпущена.
 * GPIO2       -> вход, статус ПК: LOW = ПК включен, HIGH = ПК выключен.
 * GPIO0       -> программно НЕ используется и НЕ трогается.
 *
 * Serial отключен полностью: TX/RX заняты под кнопки, а мусор от
 * Arduino Serial.begin() поверх штатного ROM boot-лога только добавил бы риска.
 * Сам ROM boot-лог на TX (до старта setup()) программно не убрать -
 * это особенность загрузчика ESP8266, а не этого скетча.
 *
 * HTTP-эндпоинты (без внутренних проверок — вся логика разрешений на OpenWrt):
 *   GET /power/on   - короткое нажатие Power.
 *   GET /power/off  - длинное удержание Power (принудительное выключение).
 *   GET /reset      - короткое нажатие Reset.
 *   GET /status     - {"pc_status":"on"|"off"}
 *
 * Плюс: ESP сама стучится на OpenWrt-программу (POST /announce на шлюз,
 * порт OPENWRT_PORT) - хендшейк раз в 10с до первого ack, потом
 * heartbeat раз в ~1.5 мин.
 */

#include <ESP8266WiFi.h>
#include <ESP8266WebServer.h>
#include <ESP8266HTTPClient.h>
#include <MD5Builder.h>

// ---- Настройки сети ----
const char* WIFI_SSID = "ВАШ_SSID";
const char* WIFI_PASS = "ВАШ_ПАРОЛЬ";

// ---- Пины ----
const uint8_t PIN_POWER     = 1; // TX -> Q1 (Power)
const uint8_t PIN_RESET     = 3; // RX -> Q3 (Reset)
const uint8_t PIN_PC_STATUS = 2; // вход статуса ПК (LOW = ON)


// ---- OpenWrt: хендшейк/heartbeat ----
const uint16_t OPENWRT_PORT = 8090;      // порт программы на роутере (сверим при написании OpenWrt-части)
const char* OPENWRT_PATH = "/cgi-bin/announce";  // единая точка приёма хендшейка/heartbeat
const char* DEVICE_PASSWORD = "poweron-esp01"; // общий пароль: метка в хендшейке + основа ключа команд md5(MAC:пароль); совпадает с uci get esptopcrsw.settings.password
const uint16_t HTTP_PORT = 80;           // наш собственный порт (для информации роутеру)

const uint32_t HANDSHAKE_INTERVAL_MS = 10000;  // пока не зарегистрированы - раз в 10с
const uint32_t HEARTBEAT_INTERVAL_MS = 90000;  // после регистрации - раз в 1.5 мин
const uint32_t WIFI_RETRY_MS = 30000;          // нет WiFi (роутер ещё не поднялся) - повторное подключение раз в 30с

bool registeredWithOpenWrt = false;
uint32_t lastAnnounceMs = 0;
uint32_t lastWifiRetryMs = 0;

// ---- Тайминги нажатий (мс) ----
// Это стартовые/безопасные значения (в т.ч. по ATX-спеке: >=4с на
// материнке гарантированно триггерит hard power-off).
// Для конкретной твоей мамки их стоит проверить и при необходимости
// подправить - вынесены отдельными константами специально для этого.
uint32_t POWER_SHORT_MS = 300;   // короткое нажатие Power -> включение
uint32_t POWER_LONG_MS  = 5000;  // удержание Power -> принудительное выключение
uint32_t RESET_SHORT_MS = 300;   // короткое нажатие Reset

ESP8266WebServer server(80);

bool pcIsOn() {
  return digitalRead(PIN_PC_STATUS) == LOW;
}

void pressButton(uint8_t pin, uint32_t durationMs) {
  digitalWrite(pin, LOW);
  delay(durationMs);
  digitalWrite(pin, HIGH);
}

String commandKey() {
  MD5Builder md5;
  md5.begin();
  md5.add(WiFi.macAddress() + ":" + String(DEVICE_PASSWORD));
  md5.calculate();
  return md5.toString().substring(0, 12);
}

bool checkKey() {
  if (server.arg("key") != commandKey()) {
    server.send(403, "text/plain", "bad key");
    return false;
  }
  return true;
}

void handlePowerOn() {
  if (!checkKey()) return;
  pressButton(PIN_POWER, POWER_SHORT_MS);
  server.send(200, "text/plain", "Power short-press sent");
}

void handlePowerOff() {
  if (!checkKey()) return;
  pressButton(PIN_POWER, POWER_LONG_MS);
  server.send(200, "text/plain", "Power long-press (force off) sent");
}

void handleReset() {
  if (!checkKey()) return;
  pressButton(PIN_RESET, RESET_SHORT_MS);
  server.send(200, "text/plain", "Reset short-press sent");
}

void handleStatus() {
  if (!checkKey()) return;
  server.send(200, "application/json",
    String("{\"pc_status\":\"") + (pcIsOn() ? "on" : "off") + "\"}");
}

void sendAnnounce() {
  WiFiClient client;
  HTTPClient http;
  String url = "http://" + WiFi.gatewayIP().toString() + ":" + String(OPENWRT_PORT) + OPENWRT_PATH;
  String payload = String("{\"mac\":\"") + WiFi.macAddress() +
                    "\",\"password\":\"" + DEVICE_PASSWORD +
                    "\",\"port\":" + String(HTTP_PORT) + "}";

  http.begin(client, url);
  http.addHeader("Content-Type", "application/json");
  int code = http.POST(payload);
  http.end();

  registeredWithOpenWrt = (code == 200);
  lastAnnounceMs = millis();
}

void setup() {
  // Кнопочные пины сразу в неактивное состояние (HIGH), до WiFi.
  pinMode(PIN_POWER, OUTPUT);
  digitalWrite(PIN_POWER, HIGH);
  pinMode(PIN_RESET, OUTPUT);
  digitalWrite(PIN_RESET, HIGH);

  pinMode(PIN_PC_STATUS, INPUT); // внешний R8 уже подтягивает, INPUT_PULLUP не нужен

  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  lastWifiRetryMs = millis();
  while (WiFi.status() != WL_CONNECTED) {
    delay(200); // без Serial - просто ждём, ретраи бесконечны
    if (millis() - lastWifiRetryMs >= WIFI_RETRY_MS) {
      lastWifiRetryMs = millis();
      WiFi.begin(WIFI_SSID, WIFI_PASS); // роутер ещё не поднялся - пробуем снова
    }
  }

  server.on("/power/on", HTTP_GET, handlePowerOn);
  server.on("/power/off", HTTP_GET, handlePowerOff);
  server.on("/reset", HTTP_GET, handleReset);
  server.on("/status", HTTP_GET, handleStatus);
  server.begin();
}

void loop() {
  server.handleClient();

  // Если WiFi отвалился - переподключаемся, не блокируя работу кнопок
  // дольше необходимого (begin() сам по себе не блокирующий).
  if (WiFi.status() != WL_CONNECTED) {
    registeredWithOpenWrt = false; // при обрыве WiFi - хендшейк заново
    if (millis() - lastWifiRetryMs >= WIFI_RETRY_MS) {
      lastWifiRetryMs = millis();
      WiFi.begin(WIFI_SSID, WIFI_PASS);
    }
    delay(100);
    return; // нет смысла стучаться в OpenWrt без WiFi
  }

  uint32_t now = millis();
  uint32_t interval = registeredWithOpenWrt ? HEARTBEAT_INTERVAL_MS : HANDSHAKE_INTERVAL_MS;
  if (now - lastAnnounceMs >= interval) {
    sendAnnounce();
  }
}
