import 'package:flutter/material.dart';

void main() {
  runApp(const WayfinderApp());
}

class WayfinderApp extends StatelessWidget {
  const WayfinderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wayfinder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(useMaterial3: true),
      home: const Scaffold(
        body: Center(
          child: Text('Wayfinder'),
        ),
      ),
    );
  }
}
