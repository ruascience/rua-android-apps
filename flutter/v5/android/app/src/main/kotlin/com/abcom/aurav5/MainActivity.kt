package com.abcom.aurav5

import io.flutter.embedding.android.FlutterFragmentActivity

/// FragmentActivity, not FlutterActivity.
///
/// `local_auth` shows the system biometric prompt through AndroidX
/// BiometricPrompt, which needs a FragmentActivity to attach to. On a plain
/// FlutterActivity the call fails at runtime with "no_fragment_activity" —
/// a crash at the moment somebody tries to unlock, not at build time.
class MainActivity : FlutterFragmentActivity()
