import 'package:flutter/material.dart';

import 'theme.dart';

/// Whether the app's started: till then, the logo shows.
final appStarted = ValueNotifier<bool>(false);

/// The logo stays up at least this long.
const splashAtLeast = Duration(milliseconds: 1500);

/// And at most this long, as starting waits for the board, which can be slow.
const splashAtMost = Duration(seconds: 4);

/// The whole DroneLab logo, as the board shows at startup, over the app
/// while it starts, then faded away, and gone: left in place, unseen, its
/// progress bar would keep the app drawing every frame for good, and the
/// computer's sound out, fed between frames, came out choppy.
class Splash extends StatefulWidget {
  final Widget child;
  const Splash({super.key, required this.child});

  @override
  State<Splash> createState() => _SplashState();
}

class _SplashState extends State<Splash> {
  bool _gone = false;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: appStarted,
      builder: (context, started, _) => Stack(children: [
        widget.child,
        if (!_gone)
          IgnorePointer(
            ignoring: started,
            child: AnimatedOpacity(
              opacity: started ? 0 : 1,
              duration: const Duration(milliseconds: 400),
              onEnd: () {
                if (started && mounted) setState(() => _gone = true);
              },
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
