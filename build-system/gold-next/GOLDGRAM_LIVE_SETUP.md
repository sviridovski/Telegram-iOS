# Goldgram Bridge Live v1 (iPhone 8 → Swiftgram 13.2)

The independent Telethon collector keeps working on jailbroken iPhone 8.
Swiftgram itself keeps capturing Telegram. Live adds an **opt-in, encrypted,
read-only pull** from iPhone 8 into the **same per-account SQLite**.

## Security and delivery

- Shared local Wi-Fi only. iPhone 8 runs a pinned-certificate HTTPS server
  on TCP port 8873, authenticating every request with a random 64-hex
  pairing secret. Swiftgram stores the secret in iOS Keychain.
- iPhone 8 only SELECTs its existing SQLite; never modifies it. It does not
  export Telegram API credentials or session files.
- On iPhone 15 the existing SQLite import queue merges the records. The
  receiver saves per-account edit and deletion cursors only **after COMMIT**.
  Failed delivery repeats, and already imported events are deduplicated.
- Ambiguous channel types or invalid batches **do not move cursors**.
  Conflicting source versions are retained for review inside the same DB.
- Swiftgram polls approximately every 12 seconds while in the foreground.
  iOS does not guarantee network work while suspended; missed deliveries
  are retried when the app is next active.
- Remote LTE-to-LTE, NAT traversal, Internet relay, automatic reboot
  recovery and 100% original preservation are **NOT** provided in v1.
- V2 source only exports edits that have an observed unedited original and
  an authentic server edit timestamp. Unknown originals cannot be recovered
  after the fact.

## Install on iPhone 8 (Termius SSH as mobile)

The original collector folder is /var/mobile/Library/GoldgramCollector
(not the rootless mirror under /var/jb/var/mobile).

~~~
cd /var/mobile/Library/GoldgramCollector
curl -fLsS 'https://raw.githubusercontent.com/sviridovski/Telegram-iOS/port/telegram-13.2/build-system/gold-next/goldgram_iphone8_live_server.py' -o goldgram_iphone8_live_server.py
python3 -m py_compile goldgram_iphone8_live_server.py
python3 goldgram_iphone8_live_server.py --dry-run
~~~

Dry run prints account ID, source SQLite path, certificate TLS SHA256 and
path to the secret file. If several DB candidates are detected, use
--db /var/mobile/Library/GoldgramCollector/EXACT.db.

First-time certificate generation requires the openssl executable on iPhone 8.
If it is absent, install OpenSSL from Procursus/Sileo; never upload the
private TLS key or the pairing token.

To read the pairing code **privately on your own screen**:

~~~
cat /var/mobile/Library/GoldgramCollector/live_bridge/live_bridge_secret.txt
~~~

To discover iPhone 8 Wi-Fi address:

~~~
ifconfig en0 | grep 'inet '
~~~

Start the HTTPS source without stopping the existing collector:

~~~
cd /var/mobile/Library/GoldgramCollector
mkdir -p logs
nohup python3 -u goldgram_iphone8_live_server.py --bind 0.0.0.0 --port 8873 >> logs/live_bridge.log 2>&1 < /dev/null &
echo "BRIDGE PID: $!"
~~~

Check that the source is still running:

~~~
ps -ax -o pid,command | grep '[g]oldgram_iphone8_live_server'
tail -n 8 /var/mobile/Library/GoldgramCollector/logs/live_bridge.log
~~~

If GitHub raw is inaccessible from iPhone 8, save the same script on the
iPhone 15 through Safari and upload it to the folder with Termius SFTP.
This is source code only: do not upload private databases or secrets.

## Pair in Swiftgram on iPhone 15

1. Install the green CI Live build from port/telegram-13.2.
2. Keep the SQLite capture option enabled. Select the matching Telegram
   account on both phones.
3. Open Goldgram archive, tap the new circular-arrows Live button.
4. Enter the local iPhone 8 IP address, the 64-character TLS certificate
   SHA-256 printed by --dry-run, and the 64-character secret from the
   local secret text file. Do not send either key to ChatGPT.
5. Enable Live. Swiftgram will poll while active, commit into its existing
   SQLite and record cursors after successful import.
6. Use the same Live menu for sync-now, status or disabling Live.

Check actual original/revision/deletion entries in Swiftgram after the first
new event. Then suspend and reopen Swiftgram to verify catch-up. A 10-repeat
manual JSON test is not a test of network delivery.

## Known caveats

- VPN routing or iOS Local Network permission may prevent local connections.
- If the server reports an unknown source SQLite schema, do not modify the
  live collector. Diagnose its file path/schema first.
- The first server launch is manual; test reboot/jailbreak recovery separately.
- Cannot guarantee instant import while iPhone 15 app is fully suspended.
- For cross-network syncing, a later opt-in encrypted relay or private
  overlay network is required. Do not open port 8873 to the public Internet.
