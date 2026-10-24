import 'dart:convert';
import 'package:http/http.dart' as http;
import 'config.dart';

Future<String> chat(
  List<Map<String, dynamic>> messages, {
  double temp = 0.2,
  int maxTokens = 250,
}) async {
  final uri = Uri.parse('${Config.baseUrl}/chat/completions');
  final body = jsonEncode({
    'model': Config.chatModel,
    'messages': messages,
    'temperature': temp,
    'max_tokens': maxTokens,
    'reasoning_effort': 'none',
  });

  final response = await http
      .post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      )
      .timeout(Config.timeout);

  if (response.statusCode != 200) {
    throw Exception('chat failed (${response.statusCode}): ${response.body}');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final choices = data['choices'] as List<dynamic>?;
  if (choices == null || choices.isEmpty) {
    throw Exception('No choices returned from chat completion');
  }

  final message = choices[0]['message'] as Map<String, dynamic>? ?? {};
  final content = (message['content'] as String? ?? '').trim();
  return content;
}

Future<Map<String, dynamic>> chatJson(
  List<Map<String, dynamic>> messages,
  Map<String, dynamic> jsonSchema, {
  int maxTokens = 200,
}) async {
  final uri = Uri.parse('${Config.baseUrl}/chat/completions');

  // Try structured outputs via json_schema first
  try {
    final body = jsonEncode({
      'model': Config.chatModel,
      'messages': messages,
      'temperature': 0.0,
      'max_tokens': maxTokens,
      'reasoning_effort': 'none',
      'response_format': {
        'type': 'json_schema',
        'json_schema': {
          'name': jsonSchema['name'] ?? 'response_schema',
          'strict': true,
          'schema': jsonSchema['schema'] ?? jsonSchema,
        },
      },
    });

    final response = await http
        .post(
          uri,
          headers: {'Content-Type': 'application/json'},
          body: body,
        )
        .timeout(Config.timeout);

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final choices = data['choices'] as List<dynamic>?;
      if (choices != null && choices.isNotEmpty) {
        final content = choices[0]['message']?['content'] as String? ?? '';
        final parsed = _extractJson(content);
        if (parsed != null) return parsed;
      }
    }
  } catch (_) {
    // Fall back to prompt-guided JSON
  }

  // Fallback: request JSON directly in prompt
  final fallbackMessages = List<Map<String, dynamic>>.from(messages);
  final lastMsg = fallbackMessages.last;
  fallbackMessages[fallbackMessages.length - 1] = {
    ...lastMsg,
    'content': '${lastMsg['content']}\n\nIMPORTANT: Respond with ONLY a valid raw JSON object matching schema: ${jsonEncode(jsonSchema)}. No markdown formatting, no other text.',
  };

  final raw = await chat(
    fallbackMessages,
    temp: 0.0,
    maxTokens: maxTokens,
  );

  final parsed = _extractJson(raw);
  if (parsed != null) return parsed;

  throw FormatException('Failed to parse JSON response: $raw');
}

Map<String, dynamic>? _extractJson(String text) {
  final trimmed = text.trim();
  try {
    return jsonDecode(trimmed) as Map<String, dynamic>;
  } catch (_) {}

  // Try extracting from markdown code block if present
  final jsonMatch = RegExp(r'```(?:json)?\s*([\s\S]*?)\s*```').firstMatch(trimmed);
  if (jsonMatch != null) {
    try {
      return jsonDecode(jsonMatch.group(1)!) as Map<String, dynamic>;
    } catch (_) {}
  }

  // Try finding outer curly braces
  final start = trimmed.indexOf('{');
  final end = trimmed.lastIndexOf('}');
  if (start != -1 && end != -1 && end > start) {
    try {
      return jsonDecode(trimmed.substring(start, end + 1)) as Map<String, dynamic>;
    } catch (_) {}
  }

  return null;
}

Future<List<double>> embed(String text) async {
  final uri = Uri.parse('${Config.baseUrl}/embeddings');
  final body = jsonEncode({
    'model': Config.embedModel,
    'input': text,
  });

  final response = await http
      .post(
        uri,
        headers: {'Content-Type': 'application/json'},
        body: body,
      )
      .timeout(Config.timeout);

  if (response.statusCode != 200) {
    throw Exception('embed failed (${response.statusCode}): ${response.body}');
  }

  final data = jsonDecode(response.body) as Map<String, dynamic>;
  final dataList = data['data'] as List<dynamic>?;
  if (dataList == null || dataList.isEmpty) {
    throw Exception('No embedding returned');
  }

  final embedding = (dataList[0]['embedding'] as List<dynamic>)
      .map((e) => (e as num).toDouble())
      .toList();
  return embedding;
}
