import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video_player/video_player.dart';

String claudeKey = '';
String openaiKey = '';
String geminiKey = '';
String userName = '';
bool autoSpeak = false;
List<Convo> convos = [];
late SharedPreferences prefs;
final FlutterTts tts = FlutterTts();

const navy = Color(0xFF0A1128);
const panel = Color(0xFF131D3B);
const gold = Color(0xFFD4AF37);
const gBase = 'https://generativelanguage.googleapis.com/v1beta';
const videoModel = 'veo-3.1-generate-preview';
const imageModel = 'gemini-2.5-flash-image';

// ---------- data ----------
class Msg {
  final String who;
  final String kind; // text, image, video
  final String text; // text, or file path for image/video
  Msg(this.who, this.kind, this.text);
  Map<String, dynamic> toJson() => {'who': who, 'kind': kind, 'text': text};
  factory Msg.fromJson(Map<String, dynamic> j) =>
      Msg(j['who'], j['kind'], j['text']);
}

class Convo {
  String id, title, tool;
  int ts;
  List<Msg> msgs;
  Convo(this.id, this.title, this.tool, this.ts, this.msgs);
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'tool': tool,
        'ts': ts,
        'msgs': msgs.map((m) => m.toJson()).toList()
      };
  factory Convo.fromJson(Map<String, dynamic> j) => Convo(
      j['id'],
      j['title'],
      j['tool'],
      j['ts'],
      (j['msgs'] as List)
          .map((m) => Msg.fromJson(Map<String, dynamic>.from(m)))
          .toList());
}

Future<void> saveConvos() async {
  await prefs.setString(
      'convos', jsonEncode(convos.map((c) => c.toJson()).toList()));
}

class Tool {
  final String id, title, sub, mode, hint, system;
  final IconData icon;
  final Color color;
  const Tool(this.id, this.title, this.sub, this.icon, this.color, this.mode,
      this.hint, this.system);
}

const tools = <Tool>[
  Tool('ask', 'Ask Anything', 'Best answer from 3 AIs', Icons.auto_awesome,
      Color(0xFFD4AF37), 'Combined', 'Ask anything...', ''),
  Tool('image', 'Create Images', 'Turn ideas into pictures',
      Icons.image_outlined, Color(0xFFFF7A59), 'Image',
      'Describe the picture...', ''),
  Tool('video', 'Create Videos', 'Text to video', Icons.movie_creation_outlined,
      Color(0xFF9575FF), 'Video', 'Describe the video...', ''),
  Tool('study', 'Study Helper', 'Learn, quiz and revise', Icons.school_outlined,
      Color(0xFF26C6DA), 'Auto', 'What do you want to study?',
      'You are a patient, clear tutor. Explain step by step in simple language, give examples, and offer a short quiz at the end.'),
  Tool('write', 'Writing Studio', 'Articles, books, posts', Icons.edit_note,
      Color(0xFF66BB6A), 'Auto', 'What should we write?',
      'You are an expert writer and editor. Write clear, engaging, well-structured content in the requested tone.'),
  Tool('biz', 'Business Assistant', 'Plans, emails, proposals',
      Icons.business_center_outlined, Color(0xFF42A5F5), 'Auto',
      'What business task do you have?',
      'You are a sharp business consultant. Give practical, concise, professional advice and ready-to-use drafts.'),
  Tool('compare', 'Compare AIs', 'See all three answers', Icons.compare_arrows,
      Color(0xFFEC407A), 'All three', 'Ask all three AIs...', ''),
  Tool('translate', 'Translate', 'Any language, natural tone', Icons.translate,
      Color(0xFFFFCA28), 'Auto', 'Text and target language...',
      'You are a professional translator. Translate accurately with a natural tone. If no target language is given, ask which one.'),
];

const starters = <String, List<String>>{
  'ask': ['Summarize the biggest AI trends', 'Give me 5 business ideas'],
  'image': ['A modern city skyline at sunrise', 'A minimal logo for a coffee brand'],
  'video': ['Drone shot over a city at sunset', 'A product reveal on a marble table'],
  'study': ['Explain photosynthesis simply', 'Quiz me on basic economics'],
  'write': ['Write an intro for a business book', 'Draft an article on leadership'],
  'biz': ['Write a client proposal outline', 'Create a one-page business plan'],
  'compare': ['What is the best way to learn fast?'],
  'translate': ['Translate "Good morning, partners" to French'],
};

Tool toolOf(Convo c) =>
    tools.firstWhere((t) => t.id == c.tool, orElse: () => tools[0]);

Color whoColor(String w) {
  switch (w) {
    case 'Claude':
      return const Color(0xFFD97757);
    case 'ChatGPT':
      return const Color(0xFF10A37F);
    case 'Gemini':
      return const Color(0xFF4285F4);
    default:
      return gold;
  }
}

// ---------- AI calls ----------
Future<dynamic> post(String url, Map<String, String> h, Map b) async {
  final r = await http.post(Uri.parse(url),
      headers: {...h, 'content-type': 'application/json'},
      body: jsonEncode(b));
  if (r.statusCode != 200) throw 'HTTP ${r.statusCode}: ${r.body}';
  return jsonDecode(r.body);
}

String pickAi() {
  if (claudeKey.isNotEmpty) return 'Claude';
  if (openaiKey.isNotEmpty) return 'ChatGPT';
  return 'Gemini';
}

List<Map<String, String>> buildTurns(List<Msg> msgs) {
  final out = <Map<String, String>>[];
  for (final m in msgs) {
    if (m.kind != 'text' || m.text.startsWith('Error')) continue;
    final role = m.who == 'You' ? 'user' : 'assistant';
    if (out.isNotEmpty && out.last['role'] == role) {
      out.last['text'] = '${out.last['text']}\n\n${m.text}';
    } else {
      out.add({'role': role, 'text': m.text});
    }
  }
  var turns = out.length > 12 ? out.sublist(out.length - 12) : out;
  while (turns.isNotEmpty && turns.first['role'] == 'assistant') {
    turns = turns.sublist(1);
  }
  return turns;
}

Future<String> ask(
    String ai, List<Map<String, String>> turns, String system) async {
  try {
    if (ai == 'Claude') {
      if (claudeKey.isEmpty) return 'Error: add your Claude key in Settings.';
      final d = await post('https://api.anthropic.com/v1/messages', {
        'x-api-key': claudeKey,
        'anthropic-version': '2023-06-01'
      }, {
        'model': 'claude-sonnet-5-5',
        'max_tokens': 1500,
        if (system.isNotEmpty) 'system': system,
        'messages':
            turns.map((t) => {'role': t['role'], 'content': t['text']}).toList(),
      });
      return d['content'][0]['text'];
    }
    if (ai == 'ChatGPT') {
      if (openaiKey.isEmpty) return 'Error: add your OpenAI key in Settings.';
      final d = await post('https://api.openai.com/v1/chat/completions',
          {'Authorization': 'Bearer $openaiKey'}, {
        'model': 'gpt-4o-mini',
        'messages': [
          if (system.isNotEmpty) {'role': 'system', 'content': system},
          ...turns.map((t) => {'role': t['role'], 'content': t['text']}),
        ],
      });
      return d['choices'][0]['message']['content'];
    }
    if (geminiKey.isEmpty) return 'Error: add your Gemini key in Settings.';
    final d = await post('$gBase/models/gemini-2.5-flash:generateContent',
        {'x-goog-api-key': geminiKey}, {
      if (system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system}
          ]
        },
      'contents': turns
          .map((t) => {
                'role': t['role'] == 'assistant' ? 'model' : 'user',
                'parts': [
                  {'text': t['text']}
                ]
              })
          .toList(),
    });
    return d['candidates'][0]['content']['parts'][0]['text'];
  } catch (e) {
    return 'Error: $e';
  }
}

Future<Msg> makeImage(String prompt) async {
  try {
    if (geminiKey.isEmpty) {
      return Msg('Nova', 'text', 'Error: add your Gemini key in Settings.');
    }
    final d = await post('$gBase/models/$imageModel:generateContent',
        {'x-goog-api-key': geminiKey}, {
      'contents': [
        {
          'parts': [
            {'text': prompt}
          ]
        }
      ],
      'generationConfig': {
        'responseModalities': ['TEXT', 'IMAGE']
      },
    });
    final parts = d['candidates'][0]['content']['parts'] as List;
    for (final p in parts) {
      final inl = p['inlineData'] ?? p['inline_data'];
      if (inl != null) {
        final bytes = base64Decode(inl['data']);
        final dir = await getApplicationDocumentsDirectory();
        final f = File(
            '${dir.path}/nova_img_${DateTime.now().millisecondsSinceEpoch}.png');
        await f.writeAsBytes(bytes);
        return Msg('Nova', 'image', f.path);
      }
    }
    return Msg('Nova', 'text',
        'Error: no image came back. Try a different description.');
  } catch (e) {
    return Msg('Nova', 'text', 'Error: $e');
  }
}

Future<Msg> makeVideo(String prompt) async {
  try {
    if (geminiKey.isEmpty) {
      return Msg('Nova', 'text', 'Error: add your Gemini key in Settings.');
    }
    final h = {
      'x-goog-api-key': geminiKey,
      'content-type': 'application/json'
    };
    final r = await http.post(
        Uri.parse('$gBase/models/$videoModel:predictLongRunning'),
        headers: h,
        body: jsonEncode({
          'instances': [
            {'prompt': prompt}
          ]
        }));
    if (r.statusCode != 200) {
      return Msg('Nova', 'text', 'Error ${r.statusCode}: ${r.body}');
    }
    final name = jsonDecode(r.body)['name'];
    for (var i = 0; i < 60; i++) {
      await Future.delayed(const Duration(seconds: 10));
      final p = await http.get(Uri.parse('$gBase/$name'), headers: h);
      final d = jsonDecode(p.body);
      if (d['done'] == true) {
        if (d['error'] != null) {
          return Msg('Nova', 'text', 'Error: ${d['error']}');
        }
        final uri = d['response']['generateVideoResponse']['generatedSamples']
            [0]['video']['uri'];
        final v = await http
            .get(Uri.parse(uri), headers: {'x-goog-api-key': geminiKey});
        final dir = await getApplicationDocumentsDirectory();
        final f = File(
            '${dir.path}/nova_vid_${DateTime.now().millisecondsSinceEpoch}.mp4');
        await f.writeAsBytes(v.bodyBytes);
        return Msg('Nova', 'video', f.path);
      }
    }
    return Msg('Nova', 'text', 'Error: the video took too long.');
  } catch (e) {
    return Msg('Nova', 'text', 'Error: $e');
  }
}

Future<void> speak(String t) async {
  await tts.stop();
  await tts.setSpeechRate(0.5);
  final clean = t.replaceAll(RegExp(r'[*#_`]'), '');
  await tts.speak(clean.length > 3000 ? clean.substring(0, 3000) : clean);
}

// ---------- start ----------
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  prefs = await SharedPreferences.getInstance();
  claudeKey = prefs.getString('claude') ?? '';
  openaiKey = prefs.getString('openai') ?? '';
  geminiKey = prefs.getString('gemini') ?? '';
  userName = prefs.getString('name') ?? '';
  autoSpeak = prefs.getBool('autoSpeak') ?? false;
  try {
    final raw = prefs.getString('convos');
    if (raw != null) {
      convos = (jsonDecode(raw) as List)
          .map((j) => Convo.fromJson(Map<String, dynamic>.from(j)))
          .toList();
    }
  } catch (_) {
    convos = [];
  }
  runApp(const NovaApp());
}

class NovaApp extends StatelessWidget {
  const NovaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nova Chat AI',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
            primary: gold, onPrimary: Colors.black, surface: panel),
        scaffoldBackgroundColor: navy,
        appBarTheme: const AppBarTheme(backgroundColor: navy, elevation: 0),
        navigationBarTheme: const NavigationBarThemeData(backgroundColor: panel),
      ),
      home: const Shell(),
    );
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  void refresh() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomePage(onChanged: refresh),
      HistoryPage(onChanged: refresh),
      SettingsPage(onChanged: refresh),
    ];
    return Scaffold(
      body: SafeArea(child: pages[tab]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => tab = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.home_outlined),
              selectedIcon: Icon(Icons.home),
              label: 'Home'),
          NavigationDestination(icon: Icon(Icons.history), label: 'History'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings'),
        ],
      ),
    );
  }
}

// ---------- home ----------
class HomePage extends StatefulWidget {
  final VoidCallback onChanged;
  const HomePage({super.key, required this.onChanged});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final c = TextEditingController();

  String greet() {
    final h = DateTime.now().hour;
    final g = h < 12
        ? 'Good morning'
        : h < 17
            ? 'Good afternoon'
            : 'Good evening';
    return userName.isEmpty ? g : '$g, $userName';
  }

  Future<void> go(Tool t, {Convo? convo, String? first}) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ChatPage(tool: t, convo: convo, first: first)));
    widget.onChanged();
    if (mounted) setState(() {});
  }

  Widget toolCard(Tool t) {
    return GestureDetector(
      onTap: () => go(t),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: panel,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: t.color.withAlpha(80)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  color: t.color.withAlpha(40),
                  borderRadius: BorderRadius.circular(12)),
              child: Icon(t.icon, color: t.color),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.title,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 2),
              Text(t.sub,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final recent = [...convos]..sort((a, b) => b.ts.compareTo(a.ts));
    return ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [
        Container(
          width: 34,
          height: 34,
          decoration: const BoxDecoration(shape: BoxShape.circle, color: gold),
          child: const Icon(Icons.auto_awesome, size: 18, color: Colors.black),
        ),
        const SizedBox(width: 10),
        const Text('NOVA CHAT AI',
            style: TextStyle(
                color: gold, fontWeight: FontWeight.bold, letterSpacing: 2)),
      ]),
      const SizedBox(height: 22),
      Text(greet(),
          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
      const SizedBox(height: 4),
      const Text('How can I help you today?',
          style: TextStyle(fontSize: 16, color: Colors.white60)),
      const SizedBox(height: 18),
      Container(
        padding: const EdgeInsets.only(left: 16, right: 6),
        decoration: BoxDecoration(
            color: panel,
            borderRadius: BorderRadius.circular(30),
            border: Border.all(color: gold.withAlpha(90))),
        child: Row(children: [
          Expanded(
            child: TextField(
              controller: c,
              decoration: const InputDecoration(
                  hintText: 'Ask Nova anything...', border: InputBorder.none),
              onSubmitted: (v) {
                final q = v.trim();
                c.clear();
                if (q.isNotEmpty) go(tools[0], first: q);
              },
            ),
          ),
          IconButton(
            icon: const Icon(Icons.arrow_circle_up, color: gold, size: 34),
            onPressed: () {
              final q = c.text.trim();
              c.clear();
              if (q.isNotEmpty) go(tools[0], first: q);
            },
          ),
        ]),
      ),
      const SizedBox(height: 24),
      const Text('Tools',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
      const SizedBox(height: 12),
      GridView.count(
        crossAxisCount: 2,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.1,
        children: tools.map(toolCard).toList(),
      ),
      if (recent.isNotEmpty) ...[
        const SizedBox(height: 24),
        const Text('Recent chats',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ...recent.take(3).map((cv) => ConvoTile(
            convo: cv, onTap: () => go(toolOf(cv), convo: cv))),
      ],
    ]);
  }
}

class ConvoTile extends StatelessWidget {
  final Convo convo;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  const ConvoTile(
      {super.key, required this.convo, required this.onTap, this.onDelete});
  @override
  Widget build(BuildContext context) {
    final t = toolOf(convo);
    final d = DateTime.fromMillisecondsSinceEpoch(convo.ts);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: panel, borderRadius: BorderRadius.circular(16)),
        child: Row(children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
                color: t.color.withAlpha(40),
                borderRadius: BorderRadius.circular(12)),
            child: Icon(t.icon, color: t.color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(convo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text('${t.title}  •  ${d.day}/${d.month}/${d.year}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
            ]),
          ),
          if (onDelete != null)
            IconButton(
                icon: const Icon(Icons.delete_outline, size: 20),
                onPressed: onDelete),
        ]),
      ),
    );
  }
}

// ---------- history ----------
class HistoryPage extends StatefulWidget {
  final VoidCallback onChanged;
  const HistoryPage({super.key, required this.onChanged});
  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  Future<void> open(Convo cv) async {
    await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => ChatPage(tool: toolOf(cv), convo: cv)));
    widget.onChanged();
    if (mounted) setState(() {});
  }

  Future<void> clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Clear all history?'),
        content: const Text('All saved chats will be deleted.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      convos.clear();
      await saveConvos();
      widget.onChanged();
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final list = [...convos]..sort((a, b) => b.ts.compareTo(a.ts));
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Expanded(
              child: Text('History',
                  style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold))),
          if (list.isNotEmpty)
            TextButton(onPressed: clearAll, child: const Text('Clear all')),
        ]),
        const SizedBox(height: 12),
        Expanded(
          child: list.isEmpty
              ? const Center(
                  child: Text('No chats yet.\nYour conversations will appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white54)))
              : ListView(
                  children: list
                      .map((cv) => ConvoTile(
                            convo: cv,
                            onTap: () => open(cv),
                            onDelete: () async {
                              convos.remove(cv);
                              await saveConvos();
                              widget.onChanged();
                              if (mounted) setState(() {});
                            },
                          ))
                      .toList(),
                ),
        ),
      ]),
    );
  }
}

// ---------- settings ----------
class SettingsPage extends StatefulWidget {
  final VoidCallback onChanged;
  const SettingsPage({super.key, required this.onChanged});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final nc = TextEditingController(text: userName);
  final cc = TextEditingController(text: claudeKey);
  final oc = TextEditingController(text: openaiKey);
  final gc = TextEditingController(text: geminiKey);
  bool show = false;
  bool auto = autoSpeak;

  Future<void> save() async {
    userName = nc.text.trim();
    claudeKey = cc.text.trim();
    openaiKey = oc.text.trim();
    geminiKey = gc.text.trim();
    autoSpeak = auto;
    await prefs.setString('name', userName);
    await prefs.setString('claude', claudeKey);
    await prefs.setString('openai', openaiKey);
    await prefs.setString('gemini', geminiKey);
    await prefs.setBool('autoSpeak', autoSpeak);
    widget.onChanged();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Settings saved')));
  }

  Widget head(String s) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 10),
        child: Text(s,
            style: const TextStyle(color: gold, fontWeight: FontWeight.bold)),
      );

  Widget field(String label, String help, TextEditingController t,
      {bool secret = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: t,
        obscureText: secret && !show,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: label,
          helperText: help,
          filled: true,
          fillColor: panel,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(14),
              borderSide: BorderSide.none),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.all(20), children: [
      const Text('Settings',
          style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
      head('PROFILE'),
      field('Your name', 'Used in your greeting', nc),
      head('API KEYS'),
      const Text('Saved only on this phone.',
          style: TextStyle(color: Colors.white54)),
      const SizedBox(height: 10),
      field('Claude key', 'console.anthropic.com', cc, secret: true),
      field('OpenAI (ChatGPT) key', 'platform.openai.com', oc, secret: true),
      field('Gemini key (chat, images, video)', 'aistudio.google.com', gc,
          secret: true),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show keys'),
          value: show,
          onChanged: (v) => setState(() => show = v)),
      head('VOICE'),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Read replies aloud automatically'),
          subtitle: const Text('You can also tap the speaker under any reply'),
          value: auto,
          onChanged: (v) => setState(() => auto = v)),
      const SizedBox(height: 10),
      FilledButton(
        onPressed: save,
        child: const Padding(
            padding: EdgeInsets.all(12), child: Text('Save settings')),
      ),
      head('ACCOUNT'),
      const Text(
          'Sign in with Google, Facebook and email is coming in the next update.',
          style: TextStyle(color: Colors.white54, height: 1.4)),
      const SizedBox(height: 24),
      const Center(
          child: Text('Nova Chat AI  •  v1.0',
              style: TextStyle(color: Colors.white38, fontSize: 12))),
    ]);
  }
}

// ---------- chat ----------
class ChatPage extends StatefulWidget {
  final Tool tool;
  final Convo? convo;
  final String? first;
  const ChatPage({super.key, required this.tool, this.convo, this.first});
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final c = TextEditingController();
  final sc = ScrollController();
  late Convo convo;
  late String mode;
  bool busy = false;
  String status = '';

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().millisecondsSinceEpoch;
    convo = widget.convo ?? Convo('$now', 'New chat', widget.tool.id, now, []);
    mode = widget.tool.mode;
    if (widget.first != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => send(widget.first!));
    }
  }

  void down() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (sc.hasClients) {
        sc.animateTo(sc.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
      }
    });
  }

  Future<void> send(String text) async {
    final q = text.trim();
    if (q.isEmpty || busy) return;
    c.clear();
    setState(() {
      convo.msgs.add(Msg('You', 'text', q));
      if (convo.title == 'New chat') {
        convo.title = q.length > 40 ? '${q.substring(0, 40)}...' : q;
      }
      busy = true;
      status = mode == 'Image'
          ? 'Creating your image...'
          : mode == 'Video'
              ? 'Creating your video. This takes a few minutes...'
              : 'Thinking...';
    });
    if (!convos.contains(convo)) convos.insert(0, convo);
    down();

    final system = widget.tool.system;
    if (mode == 'Image') {
      final m = await makeImage(q);
      setState(() => convo.msgs.add(m));
    } else if (mode == 'Video') {
      final m = await makeVideo(q);
      setState(() => convo.msgs.add(m));
    } else {
      final turns = buildTurns(convo.msgs);
      if (mode == 'Combined' || mode == 'All three') {
        final list = ['Claude', 'ChatGPT', 'Gemini'];
        final res = await Future.wait(list.map((a) => ask(a, turns, system)));
        if (mode == 'Combined') {
          final joined = [
            for (var i = 0; i < list.length; i++) '${list[i]}: ${res[i]}'
          ].join('\n\n');
          final merged = await ask(pickAi(), [
            {
              'role': 'user',
              'text':
                  'Question: $q\n\nThree AI answers:\n\n$joined\n\nIgnore any answer that starts with Error. Combine the rest into one clear, accurate best answer.'
            }
          ], system);
          setState(() => convo.msgs.add(Msg('Nova', 'text', merged)));
        } else {
          setState(() {
            for (var i = 0; i < list.length; i++) {
              convo.msgs.add(Msg(list[i], 'text', res[i]));
            }
          });
        }
      } else {
        final ai = mode == 'Auto' ? pickAi() : mode;
        final r = await ask(ai, turns, system);
        setState(
            () => convo.msgs.add(Msg(mode == 'Auto' ? 'Nova' : ai, 'text', r)));
      }
    }
    convo.ts = DateTime.now().millisecondsSinceEpoch;
    await saveConvos();
    if (!mounted) return;
    setState(() => busy = false);
    down();
    final last = convo.msgs.last;
    if (autoSpeak &&
        last.kind == 'text' &&
        last.who != 'You' &&
        mode != 'All three' &&
        !last.text.startsWith('Error')) {
      speak(last.text);
    }
  }

  Widget bubble(Msg m) {
    final me = m.who == 'You';
    Widget content;
    if (m.kind == 'image') {
      content = ImageCard(m.text);
    } else if (m.kind == 'video') {
      content = VideoCard(m.text, key: ValueKey(m.text));
    } else {
      content = SelectableText(m.text,
          style: const TextStyle(fontSize: 15, height: 1.45));
    }
    return Align(
      alignment: me ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        padding: const EdgeInsets.all(12),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.88),
        decoration: BoxDecoration(
          color: me ? const Color(0xFF22407A) : panel,
          borderRadius: BorderRadius.circular(16),
          border: me ? null : Border.all(color: whoColor(m.who).withAlpha(100)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (!me)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(m.who,
                  style: TextStyle(
                      color: whoColor(m.who),
                      fontWeight: FontWeight.bold,
                      fontSize: 12)),
            ),
          content,
          if (!me && m.kind == 'text')
            Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.volume_up_outlined, size: 18),
                onPressed: () => speak(m.text),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: m.text));
                  ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Copied')));
                },
              ),
            ]),
        ]),
      ),
    );
  }

  Widget empty() {
    final t = widget.tool;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 70,
            height: 70,
            decoration: BoxDecoration(
                shape: BoxShape.circle, color: t.color.withAlpha(40)),
            child: Icon(t.icon, size: 34, color: t.color),
          ),
          const SizedBox(height: 16),
          Text(t.title,
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          Text(t.sub, style: const TextStyle(color: Colors.white60)),
          const SizedBox(height: 22),
          ...(starters[t.id] ?? <String>[]).map((s) => GestureDetector(
                onTap: () => send(s),
                child: Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(bottom: 10),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                      color: panel,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: t.color.withAlpha(70))),
                  child: Text(s),
                ),
              )),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.tool;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          Icon(t.icon, color: t.color),
          const SizedBox(width: 10),
          Text(t.title, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
        actions: [
          IconButton(
            icon: const Icon(Icons.volume_off_outlined),
            tooltip: 'Stop voice',
            onPressed: () => tts.stop(),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(children: [
          if (t.id == 'ask')
            SizedBox(
              height: 46,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: ['Combined', 'Claude', 'ChatGPT', 'Gemini']
                    .map((m) => Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(m),
                            selected: mode == m,
                            onSelected: (_) => setState(() => mode = m),
                          ),
                        ))
                    .toList(),
              ),
            ),
          Expanded(
            child: convo.msgs.isEmpty
                ? empty()
                : ListView.builder(
                    controller: sc,
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    itemCount: convo.msgs.length,
                    itemBuilder: (_, i) => bubble(convo.msgs[i]),
                  ),
          ),
          if (busy)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(children: [
                const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(status,
                        style: const TextStyle(color: Colors.white60))),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: c,
                  minLines: 1,
                  maxLines: 4,
                  decoration: InputDecoration(
                    hintText: t.hint,
                    filled: true,
                    fillColor: panel,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 12),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(26),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: () => send(c.text),
                child: Container(
                  width: 50,
                  height: 50,
                  decoration:
                      const BoxDecoration(shape: BoxShape.circle, color: gold),
                  child: const Icon(Icons.arrow_upward, color: Colors.black),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------- media ----------
class ImageCard extends StatelessWidget {
  final String path;
  const ImageCard(this.path, {super.key});
  @override
  Widget build(BuildContext context) {
    final f = File(path);
    if (!f.existsSync()) return const Text('Image no longer available');
    return ClipRRect(
        borderRadius: BorderRadius.circular(12), child: Image.file(f));
  }
}

class VideoCard extends StatefulWidget {
  final String path;
  const VideoCard(this.path, {super.key});
  @override
  State<VideoCard> createState() => _VideoCardState();
}

class _VideoCardState extends State<VideoCard> {
  VideoPlayerController? v;

  @override
  void initState() {
    super.initState();
    final f = File(widget.path);
    if (f.existsSync()) {
      final ctrl = VideoPlayerController.file(f);
      v = ctrl;
      ctrl.initialize().then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    v?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = v;
    if (ctrl == null) return const Text('Video no longer available');
    if (!ctrl.value.isInitialized) {
      return const Padding(
          padding: EdgeInsets.all(16), child: CircularProgressIndicator());
    }
    return Column(children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: AspectRatio(
            aspectRatio: ctrl.value.aspectRatio, child: VideoPlayer(ctrl)),
      ),
      IconButton(
        iconSize: 36,
        icon: Icon(
            ctrl.value.isPlaying ? Icons.pause_circle : Icons.play_circle),
        onPressed: () => setState(() {
          ctrl.value.isPlaying ? ctrl.pause() : ctrl.play();
        }),
      ),
    ]);
  }
}
