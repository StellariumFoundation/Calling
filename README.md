# Calling 📞

**Calling** is a high-efficiency Flutter application designed for micro-call centers and automated outreach. It allows users to bulk-import phone numbers from raw text, automatically formats them for international dialing (specialized for Brazil), and manages a calling queue via a local database.

[![Build & Release Calling](https://github.com/YOUR_USERNAME/calling/actions/workflows/build_release.yml/badge.svg)](https://github.com/YOUR_USERNAME/calling/actions/workflows/build_release.yml)

## 🚀 Key Features

*   **Smart Number Extraction:** Paste messy text (emails, lists, chats), and the app will extract valid phone numbers automatically.
*   **Brazil-Optimized Parsing:** 
    *   Defaults to **Brazil (+55)** international format.
    *   **9th Digit Auto-Fix:** Automatically detects and injects the "9" for Brazilian mobile numbers if missing (e.g., converts `6188377338` to `+5561988377338`).
*   **Direct Dialing:** Uses `flutter_phone_direct_caller` to initiate calls immediately with a single tap (bypassing the system dialer confirmation on Android).
*   **Persistent Queue Management:** 
    *   Uses **SQLite** to store numbers.
    *   Tracks status: `Total`, `Called`, and `Remaining`.
    *   **Rotation Logic:** Once the list is finished, the app offers to reset the queue and start calling from the beginning.
*   **Permission Handling:** Integrated UI for requesting and managing Android `CALL_PHONE` permissions.

## 🛠 Installation & Setup

### 1. Prerequisites
*   Flutter SDK: `^3.0.0`
*   Android SDK (API 21 or higher)

### 2. Dependencies
Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  sqflite: ^2.3.0
  path: ^1.9.1
  phone_numbers_parser: ^8.1.0
  flutter_phone_direct_caller: ^2.1.0
  permission_handler: ^11.3.1
```

### 3. Android Configuration
To allow direct calling, add this to `android/app/src/main/AndroidManifest.xml` (inside the `<manifest>` tag, above `<application>`):

```xml
<uses-permission android:name="android.permission.CALL_PHONE" />
```

To avoid collisions with other apps, ensure your `applicationId` is unique in `android/app/build.gradle.kts`:
```kotlin
defaultConfig {
    applicationId = "com.jv.calling"
}
```

## 📖 How to Use

1.  **Import:** Paste any text containing phone numbers into the input field and press **"Extract & Save"**.
2.  **Monitor:** Check the status bar at the top to see how many numbers are pending in your database.
3.  **Call:** Press the large green **"CALL NEXT"** button. The app will immediately dial the first available number.
4.  **Auto-Update:** When you return to the app after the call, it will automatically mark that number as "Called" and update your statistics.
5.  **Re-dial:** If you get a busy signal, use the **"Call Again"** button to immediately redial the last number without moving to the next one in the queue.

## 🤖 CI/CD Build Process

This repo includes a GitHub Actions workflow that automatically builds:
*   **Android:** Universal APK and Split APKs (arm64, armv7, x86_64).
*   **Linux:** Compressed `.tar.gz` bundle (requires `libsqlite3-dev`).
*   **Web:** Production-ready Zip bundle.

Every push to `main` or `master` triggers a new Release on the GitHub "Releases" page.

## 🛠 Tech Stack

*   **Language:** Dart / Flutter
*   **Database:** Sqflite (SQLite)
*   **Parser:** Phone Numbers Parser (E.164 compliance)
*   **CI/CD:** GitHub Actions

---
*Created by John Victor
