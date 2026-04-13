import 'dart:ui';
import 'package:flutter/material.dart';

class WelcomePage extends StatelessWidget {
  final bool setupCompleted;
  final VoidCallback onGetStarted;
  final VoidCallback onGoToProfile;

  const WelcomePage({
    super.key,
    required this.setupCompleted,
    required this.onGetStarted,
    required this.onGoToProfile,
  });

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFFF2F2F2), // soft light gray base
      body: Stack(
        children: [
          // ===== Minimalist Gradient Blobs =====
          Positioned(
            top: -80,
            right: -60,
            child: _buildBlob(
              size: 250,
              colors: [
                const Color(0xFFE0A800).withOpacity(0.6),
                const Color(0xFFE0A800).withOpacity(0.2),
              ],
              blur: 70,
            ),
          ),
          Positioned(
            bottom: -100,
            left: -100,
            child: _buildBlob(
              size: 350,
              colors: [
                const Color(0xFF1A7A72).withOpacity(0.5),
                const Color(0xFF1A7A72).withOpacity(0.15),
              ],
              blur: 80,
            ),
          ),
          Positioned(
            bottom: 80,
            right: -60,
            child: _buildBlob(
              size: 250,
              colors: [
                const Color(0xFF7B5FE0).withOpacity(0.4), // purple-violet accent
                const Color(0xFF7B5FE0).withOpacity(0.1),
              ],
              blur: 70,
            ),
          ),

          // ===== Safe Area Content =====
          SafeArea(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: size.width * 0.08),
              child: Column(
                children: [
                  SizedBox(height: size.height * 0.08),

                  Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/images/welcome.png',
                          width: size.width * 0.1, // match text scale
                          height: size.width * 0.1,
                          fit: BoxFit.contain,
                        ),

                        const SizedBox(width: 6),

                        RichText(
                          text: TextSpan(
                            children: [
                              TextSpan(
                                text: 'Phish',
                                style: TextStyle(
                                  fontSize: size.width * 0.1,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFF1A7A72),
                                ),
                              ),
                              TextSpan(
                                text: 'Sense',
                                style: TextStyle(
                                  fontSize: size.width * 0.1,
                                  fontWeight: FontWeight.bold,
                                  color: const Color(0xFFE0A800),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                  const SizedBox(height: 8),
                  const Text(
                    'Scan instantly to detect and identify safe or phishing messages',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: Color(0xFF888880),
                    ),
                  ),

                  SizedBox(height: size.height * 0.06),

                  // ===== Info Card =====
                  Container(
                    padding: EdgeInsets.all(size.width * 0.07),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.06),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: const [
                        Icon(
                          Icons.security_rounded,
                          size: 48,
                          color: Color(0xFF1A7A72),
                        ),
                        SizedBox(height: 12),
                        Text(
                          'Welcome to PhishSense',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        SizedBox(height: 8),
                        Text(
                          'Manually scan SMS messages to identify phishing, scams, and suspicious links using intelligent on-device analysis.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.5,
                            color: Colors.grey,
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // ===== Buttons =====
                  Padding(
                    padding: EdgeInsets.only(bottom: size.height * 0.04),
                    child: SizedBox(
                      width: double.infinity,
                      height: size.height * 0.065,
                      child: ElevatedButton(
                        onPressed: setupCompleted ? onGoToProfile : onGetStarted,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A7A72),
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                        child: Text(
                          setupCompleted ? 'GO TO PROFILE' : 'GET STARTED',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            letterSpacing: 1.2,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Build a soft blurred radial blob
  Widget _buildBlob({required double size, required List<Color> colors, double blur = 50}) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: colors,
          radius: 0.8,
        ),
      ),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
        child: Container(
          color: Colors.transparent,
        ),
      ),
    );
  }
}
