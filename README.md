# GateIO SMC Pro Android — Complex Build

A Flutter Android dashboard for Gate.io USDT perpetual futures.

## Included

- Gate.io TESTNET / LIVE switch.
- DRY-RUN default.
- Secure storage for API key/secret.
- HMAC-SHA512 Gate API v4 signing.
- USDT perpetual contracts discovery.
- 15-minute closed-candle SMC-style engine:
  - EMA200 trend
  - liquidity sweep proxy
  - BOS proxy
  - FVG proxy
  - ATR-based stop
  - RR configurable, default 1:3
- Risk per position, default 2% of reported futures equity.
- Isolated leverage, default 15x.
- Max open positions.
- Entry / SL / TP display.
- Testnet/live connection check.
- Optional order submission with exchange-side TP/SL trigger fields.
- Logs, positions and signal history.
- Flutter test included.

## Important

This is a serious trading prototype, not a guarantee of profitability.
The SMC rules are deterministic proxies, not a certified reproduction of any discretionary trader.

Do not put withdrawal permission on the Gate API key.
For first testing use Gate TESTNET and DRY-RUN.

The app stores API credentials in Android secure storage, but a mobile app that directly holds an exchange secret is inherently higher-risk than a server-side execution architecture.

## 1. Install tools on Windows

Install:
1. Flutter SDK
2. Android Studio
3. Android SDK + Platform Tools
4. Git

Then verify:

    flutter doctor

Fix all Android license/toolchain errors before building.

## 2. Create the Flutter shell

Open PowerShell:

    mkdir gateio_smc_pro
    cd gateio_smc_pro
    flutter create --org com.neurobro --project-name gateio_smc_pro .

Copy the `lib/`, `test/`, and `pubspec.yaml` from this package into the generated project.

Then:

    flutter pub get
    dart format lib test
    flutter analyze
    flutter test

## 3. Android Internet permission

In:
`android/app/src/main/AndroidManifest.xml`

Inside `<manifest ...>` add:

    <uses-permission android:name="android.permission.INTERNET"/>

Flutter Android templates normally already include it for debug; keep it explicit for release.

## 4. Build debug APK

    flutter build apk --debug

APK:

    build/app/outputs/flutter-apk/app-debug.apk

Install:

    adb install -r build/app/outputs/flutter-apk/app-debug.apk

Or:

    flutter install

## 5. Build release APK

For a personal sideload:

    flutter build apk --release

APK:

    build/app/outputs/flutter-apk/app-release.apk

For Play Store, use a signed App Bundle:

    flutter build appbundle --release

Output:

    build/app/outputs/bundle/release/app-release.aab

See Flutter's Android release documentation for signing.

## 6. First Gate.io setup

1. Create a Gate.io API key.
2. Enable only the permissions required for futures trading.
3. Do NOT enable withdrawals.
4. If Gate offers IP restrictions, use them when the deployment architecture supports a stable IP.
5. Start with TESTNET.
6. In the app:
   - TESTNET = ON
   - DRY-RUN = ON
   - risk = 2
   - RR = 3
   - leverage = 15
7. Press SAVE & TEST CONNECTION.
8. Press START BOT.

## 7. LIVE sequence

Only after TESTNET and DRY-RUN have been exercised:

1. TESTNET OFF
2. DRY-RUN remains ON
3. SAVE & TEST
4. Check equity and positions
5. Keep max positions low
6. Only then enable SEND ORDERS
7. Start the bot and monitor logs/positions

The app shows a LIVE confirmation dialog before starting.

## 8. How sizing works

Approximate position risk:

    riskAmount = equity * riskPercent / 100

For a linear USDT contract, the app estimates:

    riskPerContract = abs(entry - stop) * quantoMultiplier

Then:

    size = riskAmount / riskPerContract

The result is rounded to the contract minimum and capped by its maximum.

This is an estimate. Fees, slippage, funding, trigger execution and contract-specific rules can change realized P&L.

## 9. Android background limitation

This version intentionally keeps the trading loop inside the Flutter process and does not claim guaranteed 24/7 background execution.

Android 15 places a 6-hour-per-24-hour limit on `dataSync` foreground services for apps targeting API 35+. A mobile-only bot therefore should not be treated as a guaranteed 24/7 execution server.

For true 24/7 execution, use:

Android app -> HTTPS backend -> Gate API

The app then becomes a secure dashboard/controller rather than the sole execution engine.

## 10. Architecture for the next production phase

Recommended production components:

- REST API backend
- encrypted server-side secret store
- Gate futures WebSocket market data
- REST fallback
- order idempotency
- startup reconciliation
- open-order reconciliation
- exchange-side TP/SL verification
- partial-fill handling
- max daily loss
- max concurrent risk
- cooldown after stop
- circuit breaker
- stale-price detection
- rate limiter
- audit log
- notification service
- health check
- watchdog
- server-side execution

Gate provides futures WebSocket channels for candlesticks and authenticated private data; use WebSocket instead of polling every symbol on a short interval when moving to production.

## 11. Common errors

### 401 / 403
Check API key, secret, permissions, environment, and Gate IP whitelist.

### Timestamp/signature error
Make sure device time is correct. Gate API requires a current timestamp and uses HMAC-SHA512.

### Order rejected
Check:
- contract state
- leverage limit
- minimum size
- maximum size
- position mode
- available balance
- risk limit
- trigger prices
- market slippage

### App compiles but no signals
SMC conditions are intentionally strict. Check the Signals and Log tabs.

## 12. Safety defaults

TESTNET = true
DRY-RUN = true
risk = 2%
RR = 3
leverage = 15x isolated
max positions = 3
scan = 60 seconds
interval = 15m

Do not assume a 2% theoretical stop risk is a guaranteed 2% maximum realized loss.
