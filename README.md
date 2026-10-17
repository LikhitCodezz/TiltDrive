# TiltDrive — Anything but a Game Controller

**The phone is the wheel. The laptop is the track.** TiltDrive is a small Android motion controller and browser arcade game, paired over your local Wi-Fi with a short room code.

## The brief, covered

1. **Motion controls:** Android reads gyro, rotation-vector orientation, and accelerometer data. Lean steers; a sharp shake triggers a hop.
2. **Pairing:** the laptop game shows a five-digit room code. The phone joins that room using the laptop's local IP address.
3. **Live stream:** the phone sends compact control packets over WebSockets 30 times per second. The phone shows a ping measurement.
4. **Phone-driven game:** tilt, shake, touch drift, and tap jump control Neon Run on the laptop. Keyboard controls are only a fallback for setup or testing.
5. **Calibration:** Set Neutral records the phone's current orientation so it becomes the steering center.
6. **Connection feedback:** both screens show the connection state; both reconnect automatically after a short Wi-Fi interruption.

**Bonus:** more than one phone can join the room, the phone has touch controls and vibration feedback, and the controller displays live round-trip latency.

## What the pieces are

- `lib/main.dart` is the Android phone controller: pairing, sensor readings, calibration, touch controls, and reconnection.
- `android/app/src/main/kotlin/.../MainActivity.kt` bridges Android's real motion sensors into Flutter.
- `game/game.html` is the laptop game.
- `server.py` is the small local relay that pairs the two screens and forwards controls.

The game server is a **local demo relay**, not an internet service. It has no accounts and should only be used on a trusted local network. The room code prevents accidental cross-pairing; it isn't meant to protect an exposed public server.

## Windows setup

### 1. Start the laptop game

1. Install Python 3.10 or newer if needed.
2. Extract the project folder.
3. Double-click `run_game.bat`. It installs the one small Python dependency, then starts the relay.
4. If Windows Firewall asks, allow Python on **Private networks** so your phone can connect.
5. Open `http://localhost:8000` on the laptop. The game displays the room code.
6. Keep the black server window open while playing.

### 2. Run the phone app

You need Flutter and Android Studio. The app has no third-party Flutter packages.

1. Double-click `prepare_android.bat` once. It asks your installed Flutter SDK to generate its matching Gradle launcher in a temporary folder, then copies the launcher into this project. It keeps the TiltDrive app files untouched.
2. In Android Studio, choose **Open** and select this `TiltDrive` folder.
3. Connect an Android phone to the laptop with USB and allow USB debugging on the phone, or choose an Android emulator.
4. Select the phone at the top of Android Studio and press the green **Run** button. The first build can take a few minutes.
5. If Android Studio does not recognize this as Flutter, install/enable the Flutter plugin and point it at your Flutter SDK folder.

After running `prepare_android.bat` once, you can also run it from PowerShell opened in this folder:

```powershell
flutter pub get
flutter run
```

To make an installable debug APK:

```powershell
flutter build apk --debug
```

The APK appears at `build\app\outputs\flutter-apk\app-debug.apk`.

### 3. Pair and play

1. Put the phone and laptop on the **same Wi-Fi**.
2. Find the laptop's Wi-Fi IPv4 address: open a second PowerShell window, run `ipconfig`, and find **IPv4 Address** under the active Wi-Fi adapter. It usually looks like `192.168.1.23`.
3. In TiltDrive, enter that address and the five-digit room code from the laptop game; tap **Link Phone to Game**.
4. On the laptop, click **Start Neon Run**.
5. Hold the phone sideways like a steering wheel. Tap **Set Neutral**, lean to steer, shake or tap **Jump** to hop barriers, and use the touch drift buttons if you prefer.

The laptop game also accepts arrow keys and Space as a fallback. To stop the relay, press `Ctrl+C` in its black server window.

## If something goes sideways

- **Phone says reconnecting:** check that both devices share Wi-Fi, the IP is the laptop's current IPv4 address, the room code matches, and the Python firewall prompt allowed Private networks.
- **Room not found:** the game server may have restarted, creating a fresh code. Refresh the laptop game and enter its new code in the phone app.
- **No movement:** tap **Set Neutral** while holding the phone steady, then lean farther. Check the phone's motion sensors; the touch buttons still work as a backup.
- **No ping:** the game relay must be running. A ping around 20–100 ms is normal on local Wi-Fi; the exact result depends on the network.

## Recording a judging demo

Use a phone screen recorder and a laptop screen recorder (or film both screens together). Show the room code, pair the phone, tap Set Neutral, steer with a visible tilt, then shake/tap Jump and show the ping. A short clip of the phone visibly controlling the laptop is stronger than a screen full of code.

## Stack and latency choices

Flutter renders the phone UI; a tiny Kotlin platform channel reads Android sensors directly; Python's `websockets` package relays packets to a plain HTML Canvas game. The relay stays on the LAN. The controller sends at 30 Hz, packets contain only the latest normalized tilt and jump state, and the displayed ping is a round-trip sample. This avoids polling databases or sending sensor data to a cloud service. Actual latency still depends on the Wi-Fi and the laptop/phone hardware.
