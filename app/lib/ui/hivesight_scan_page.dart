import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../comm/hivesight_invite.dart';
import '../comm/hivesight_join.dart';
import 'theme.dart';

const _channel = MethodChannel('dronelab/hivesight');

/// The camera, full screen, looking for a Guide's HiveSight code (a QR code,
/// read on the phone with the scanner's bundled model, so it works with no
/// internet). Pops with the invitation once it sees a good one; anything
/// else is said and the scanning goes on. The camera's permission is asked
/// when this opens, which is when the person has tapped Scan.
class HiveSightScanPage extends StatefulWidget {
  const HiveSightScanPage({super.key});

  @override
  State<HiveSightScanPage> createState() => _HiveSightScanPageState();
}

class _HiveSightScanPageState extends State<HiveSightScanPage> {
  final _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode], detectionSpeed: DetectionSpeed.noDuplicates);
  String? _said; // the last thing said about a code, so it isn't said again and again
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_done) return;
    for (final b in capture.barcodes) {
      final text = b.rawValue;
      if (text == null) continue;
      final code = await readCode(text);
      if (!mounted || _done) return;
      if (code.result == CodeResult.ok) {
        _done = true;
        Navigator.pop<HiveSightInvite>(context, code.invite);
        return;
      }
      if (_said != text) {
        _said = text;
        ScaffoldMessenger.of(context)
          ..clearSnackBars()
          ..showSnackBar(SnackBar(content: Text(code.problem)));
      }
    }
  }

  Widget _refused(MobileScannerException e) {
    final denied = e.errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.no_photography_outlined, size: 48, color: Kc.muted),
            const SizedBox(height: 12),
            Text(
              denied
                  ? "DroneLab can't use the camera. Allow it in Android's settings to scan a code."
                  : "The camera can't be used just now${e.errorDetails?.message == null ? '' : ': ${e.errorDetails!.message}'}",
              textAlign: TextAlign.center,
            ),
            if (denied) ...[
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => _channel.invokeMethod<void>('appSettings'),
                child: const Text("Open Android's settings"),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Scan a Guide's code")),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect, errorBuilder: (context, e) => _refused(e)),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Text(
              "Point the camera at the code on the Guide's screen.",
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, shadows: [Shadow(blurRadius: 6)]),
            ),
          ),
        ],
      ),
    );
  }
}
