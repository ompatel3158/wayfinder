class Config {
  static const String baseUrl = 'http://localhost:1235/v1';
  static const String chatModel = 'google/gemma-4-e4b';
  static const String embedModel = 'text-embedding-nomic-embed-text-v1.5';
  static const Duration timeout = Duration(seconds: 60);
}
