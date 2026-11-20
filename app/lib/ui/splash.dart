import 'package:flutter/material.dart';

import 'theme.dart';

/// Whether the app's started: till then, the logo shows.
final appStarted = ValueNotifier<bool>(false);

/// The logo stays up at least this long.
const splashAtLeast = Duration(milliseconds: 1500);

/// And at most this long, as starting waits for the board, which can be slow.
const splashAtMost = Duration(seconds: 4);

/// The whole DroneLab logo, as the board shows at startup, over the app
/// while it starts, then faded away.
class Splash extends StatelessWidget {
  final Widget child;
  const Splash({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appStarted,
      builder: (context, started, _) => Stack(children: [
        child,
        IgnorePointer(
          ignoring: started,
          child: AnimatedOpacity(
            opacity: started ? 0 : 1,
            duration: const Duration(milliseconds: 400),
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Image.asset('assets/dronelab_logo.png', fit: BoxFit.contain),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: 120,
                    child: LinearProgressIndicator(
                        minHeight: 2, color: Kc.green, backgroundColor: Kc.green.withValues(alpha: 0.15)),
                  ),
                ]),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}
