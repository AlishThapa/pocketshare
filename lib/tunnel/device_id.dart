import 'dart:convert';

import 'package:crypto/crypto.dart';

/// How this phone names itself to the provisioning Worker.
///
/// The id has one job: let a phone prove it is the same phone after the app
/// has been uninstalled and reinstalled, so it can take back the address it
/// already had. A value kept only in app storage cannot do that — uninstall
/// wipes it — which is why this derives from ANDROID_ID instead.
///
/// Pure, so the derivation is testable without a device.
class DeviceId {
  DeviceId._();

  /// Mixed into the hash so the result is specific to this app. Not a secret
  /// — it ships in the APK — and it does not need to be. It exists so the id
  /// the Worker stores cannot be matched against the same phone's ANDROID_ID
  /// as seen by anything else.
  static const salt = 'pocketshare-device-v1';

  /// A stable, opaque id derived from [androidId].
  ///
  /// Hashed rather than sent raw: the Worker has no use for the real value,
  /// and an identifier that outlives the app is worth not handing out. The
  /// `a` prefix marks the derivation, so a stored id can be told apart from
  /// the random ones earlier builds generated.
  static String fromAndroidId(String androidId) {
    final digest = sha256.convert(utf8.encode('$salt:$androidId'));
    return 'a${base64Url.encode(digest.bytes).replaceAll('=', '').substring(0, 32)}';
  }

  /// Whether ANDROID_ID can be trusted on this device.
  ///
  /// Some pre-8.0 ROMs return a hard-coded value shared by every device of
  /// that model. Deriving from it would hand several phones the same id and
  /// let any of them take another's address.
  static bool usable(String? androidId) =>
      androidId != null &&
      androidId.trim().isNotEmpty &&
      androidId != '9774d56d682e549c';
}
