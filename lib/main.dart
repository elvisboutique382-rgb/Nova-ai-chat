import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

const claudeKey = 'PASTE_CLAUDE_KEY_HERE';
const openaiKey = 'PASTE_OPENAI_KEY_HERE';
const geminiKey = 'PASTE_GEMINI_KEY_HERE';

const videoModel = 'veo-3.1-generate-preview';
const gBase = 'https://generativelanguage.googleapis.com/v1beta';

void main() => runApp(MaterialApp(
      title: 'Nova Chat AI',
      theme: ThemeData(
          colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
      home: const Chat(),
    ));

Future<dynamic> post(String url, Map<String, String> h, Map b) async {
  final r = await http.post(Uri.parse(url),
      headers: {...h, 'content-type': 'application/json'},
      body: jsonEncode(b));
  if (r.statusCode != 200) throw 'HTTP ${r.statusCode}: ${r.body}';
  return jsonDecode(r.body);
}

Future<String> ask(String ai, String q) async {
  try {
    if (ai == 'Claude') {
      final d = await post('https://api.anthropic.com/v1/messages', {
        'x-api-key': claudeKey,
        'anthropic-version': '2023-06-01'
      }, {
        'model': 'claude-sonnet-5-5',
        'max_tokens': 1000,
        'messages': [{'role': 'user', 'content': q}]
      });
      return d['content'][0]['text'];
    }
    if (ai == 'ChatGPT') {
      final d = await post('https://api.openai.com/v1/chat/completions',
          {'Authorization': 'Bearer $openaiKey'}, {
        'model': 'gpt-4o-mini',
        'messages': [{'role': 'user', 'content': q}]
      });
      return d['choices'][0]['message']['content'];
    }
    final d = await post(
        '$gBase/models/gemini-2.5-flash:generateContent?key=$geminiKey',
        {}, {
      'contents': [{'parts': [{'text': q}]}]
    });
    return d['candidates'][0]['content']['parts'][0]['text'];
  } catch (e) {
    return 'Error: $e';
  }
}

class VideoMsg {
  final String path;
  VideoMsg(this.path);
}

Future<Object> makeVideo(String prompt) async {
  try {
    final h = {
      'x-goog-api-key': geminiKey,
      'content-type': 'application/json'
    };
    final r = await http.post(
        Uri.parse('$gBase/models/$videoModel:predictLongRunning'),
        headers: h,
        body: jsonEncode({
          'instances': [{'prompt': prompt}]
        }));
    if (r.statusCode != 200) return 'Error ${r.statusCode}: ${r.body}';
    final name = jsonDecode(r.body)['name'];
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(seconds: 10));
      final p = await http.get(Uri.parse('$gBase/$name'), headers: h);
      final d = jsonDecode(p.body);
      if (d['done'] == true) {
        if (d['error'] != null) return 'Error: ${d['error']}';
        final uri = d['response']['generateVideoResponse']
            ['generatedSamples'][0]['video']['uri'];
        final v = await http.get(Uri.parse(uri),
            headers: {'x-goog-api-key': geminiKey});
        final dir = await getTemporaryDirectory();
        final f = File(
            '${dir.path}/nova_${DateTime.now().millisecondsSinceEpoch}.mp4');
        await f.writeAsBytes(v.bodyBytes);
        return VideoMsg(f.path);
      }
    }
    return 'Error: the video took too long';
  } catch (e) {
    return 'Error: $e';
  }
}

class VideoCard extends StatefulWidget {
  final String path;
  const VideoCard(this.path, {super.key});
  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  late final VideoPlayerController v;
  @override
  void initState() {
    super.initState();
    v = VideoPlayerController.file(File(widget.path));
    v.initialize().then((_) {
      setState(() {});
      v.play();
    });
  }

  @override
  void dispose() {
    v.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!v.value.isInitialized) {
      return const Padding(
          padding: EdgeInsets.all(16), child: CircularProgressIndicator());
    }
    return Column(children: [
      AspectRatio(aspectRatio: v.value.aspectRatio, child: VideoPlayer(v)),
      IconButton(
        icon: Icon(v.value.isPlaying ? Icons.pause : Icons.play_arrow),
        onPressed: () => setState(() {
          v.value.isPlaying ? v.pause() : v.play();
        }),
      ),
    ]);
  }
}

class Chat extends StatefulWidget {
  const Chat({super.key});
  @override
  State<Chat> createState() => _ChatState();
}

class _ChatState extends State<Chat> {
  final c = TextEditingController();
  final msgs = <Object>[];
  String ai = 'Combined';
  bool busy = false;

  Future<void> send() async {
    final q = c.text.trim();
    if (q.isEmpty || busy) return;
    c.clear();
    setState(() {
      msgs.add('You: $q');
      busy = true;
    });

    if (ai == 'Video') {
      setState(() => msgs.add('Nova: Creating your video. This takes a few minutes...'));
      final res = await makeVideo(q);
      setState(() {
        msgs.add(res);
        busy = false;
      });
      return;
    }

    final multi = ai == 'All three' || ai == 'Combined';
    final list = multi ? ['Claude', 'ChatGPT', 'Gemini'] : [ai];
    final res = await Future.wait(list.map((a) => ask(a, q)));
    if (ai == 'Combined') {
      final joined = [
        for (var i = 0; i < list.length; i++) '${list[i]}: ${res[i]}'
      ].join('\n\n');
      final merged = await ask(
          'Claude',
          'Question: $q\n\nThree AI answers:\n\n$joined\n\n'
          'Ignore any answer that starts with Error. '
          'Combine the rest into one clear, accurate best answer.');
      setState(() => msgs.add('Nova: $merged'));
    } else {
      setState(() {
        for (var i = 0; i < list.length; i++) {
          msgs.add('${list[i]}: ${res[i]}');
        }
      });
    }
    setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Nova Chat AI'), actions: [
        DropdownButton<String>(
          value: ai,
          items: ['Combined', 'All three', 'Claude', 'ChatGPT', 'Gemini', 'Video']
              .map((e) => DropdownMenuItem(value: e, child: Text(e)))
              .toList(),
          onChanged: (v) => setState(() => ai = v!),
        ),
        const SizedBox(width: 8),
      ]),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView.builder(
              itemCount: msgs.length,
              itemBuilder: (_, i) {
                final m = msgs[i];
                return Padding(
                  padding: const EdgeInsets.all(8),
                  child: m is VideoMsg
                      ? VideoCard(m.path, key: ValueKey(m.path))
                      : SelectableText(m as String),
                );
              },
            ),
          ),
          if (busy) const LinearProgressIndicator(),
          Row(children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: TextField(
                    controller: c,
                    decoration: InputDecoration(
                        hintText: ai == 'Video'
                            ? 'Describe your video...'
                            : 'Ask Nova...'),
                    onSubmitted: (_) => send()),
              ),
            ),
            IconButton(icon: const Icon(Icons.send), onPressed: send),
          ]),
        ]),
      ),
    );
  }
}
