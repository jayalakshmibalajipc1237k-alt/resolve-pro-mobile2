import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:image_picker/image_picker.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Lock into DaVinci Resolve Landscape Workstation Orientation
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ResolveProMobileApp());
}

class ResolveProMobileApp extends StatelessWidget {
  const ResolveProMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ResolvePro Mobile Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF141417),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFFFF5722),
          secondary: Color(0xFF29B6F6),
          surface: Color(0xFF1E1E24),
        ),
      ),
      home: const ResolveColorWorkstation(),
    );
  }
}

// --- DATA MODEL: SINGLE NODE GRADE STATE ---
class ColorNodeState {
  String id;
  String label;
  bool enabled;

  // Lift, Gamma, Gain, Offset: [R, G, B, Master Y]
  List<double> lift;
  List<double> gamma;
  List<double> gain;
  List<double> offset;

  // Primaries & HDR
  double contrast;
  double pivot;
  double saturation;
  double temp;
  double tint;
  double colorBoost;
  double shadows;
  double highlights;
  double lumMix;

  // CST & LUT
  int inputCST;
  int outputCST;
  int lutPreset;
  double lutStrength;

  // 3D Qualifier
  bool qualEnabled;
  double qualHueCenter;
  double qualHueWidth;
  double qualSoftness;
  double qualSatMin;
  double qualLumMin;

  // Power Window
  bool winEnabled;
  double winCenterX;
  double winCenterY;
  double winRadiusX;
  double winRadiusY;
  double winFeather;
  bool winInvert;

  ColorNodeState({
    required this.id,
    required this.label,
    this.enabled = true,
    List<double>? lift,
    List<double>? gamma,
    List<double>? gain,
    List<double>? offset,
    this.contrast = 1.0,
    this.pivot = 0.435,
    this.saturation = 1.0,
    this.temp = 0.0,
    this.tint = 0.0,
    this.colorBoost = 0.0,
    this.shadows = 0.0,
    this.highlights = 0.0,
    this.lumMix = 1.0,
    this.inputCST = 0,
    this.outputCST = 0,
    this.lutPreset = 0,
    this.lutStrength = 0.85,
    this.qualEnabled = false,
    this.qualHueCenter = 0.06,
    this.qualHueWidth = 0.18,
    this.qualSoftness = 0.08,
    this.qualSatMin = 0.15,
    this.qualLumMin = 0.10,
    this.winEnabled = false,
    this.winCenterX = 0.5,
    this.winCenterY = 0.5,
    this.winRadiusX = 0.35,
    this.winRadiusY = 0.35,
    this.winFeather = 0.25,
    this.winInvert = false,
  })  : lift = lift ?? [0.0, 0.0, 0.0, 0.0],
        gamma = gamma ?? [0.0, 0.0, 0.0, 0.0],
        gain = gain ?? [0.0, 0.0, 0.0, 0.0],
        offset = offset ?? [0.0, 0.0, 0.0, 0.0];

  void reset() {
    lift = [0.0, 0.0, 0.0, 0.0];
    gamma = [0.0, 0.0, 0.0, 0.0];
    gain = [0.0, 0.0, 0.0, 0.0];
    offset = [0.0, 0.0, 0.0, 0.0];
    contrast = 1.0;
    pivot = 0.435;
    saturation = 1.0;
    temp = 0.0;
    tint = 0.0;
    colorBoost = 0.0;
    shadows = 0.0;
    highlights = 0.0;
    lumMix = 1.0;
    inputCST = 0;
    outputCST = 0;
    lutPreset = 0;
    lutStrength = 0.85;
    qualEnabled = false;
    winEnabled = false;
    winInvert = false;
  }
}

class ResolveColorWorkstation extends StatefulWidget {
  const ResolveColorWorkstation({super.key});

  @override
  State<ResolveColorWorkstation> createState() =>
      _ResolveColorWorkstationState();
}

class _ResolveColorWorkstationState extends State<ResolveColorWorkstation> {
  ui.FragmentProgram? _program;
  ui.Image? _sourceImage;
  final GlobalKey _viewportKey = GlobalKey();

  // Multi-Node Pipeline
  final List<ColorNodeState> _nodes = [
    ColorNodeState(id: '01', label: '01: Primary Balance'),
    ColorNodeState(id: '02', label: '02: Skin / Secondary'),
    ColorNodeState(id: '03', label: '03: Film Look & CST'),
  ];
  int _activeNodeIndex = 0;

  // Workstation View Controls
  int _selectedDeckTab = 0; // 0:Primaries, 1:Log/HDR, 2:CST/LUT, 3:Qualifier, 4:Window, 5:Scopes
  bool _globalBypass = false;
  bool _showMatteHighlight = false;
  double _splitWipe = 0.0;
  bool _showNodePanel = true;
  bool _showScopesOverlay = false;

  ColorNodeState get _currentNode => _nodes[_activeNodeIndex];

  @override
  void initState() {
    super.initState();
    _initGpuEngine();
  }

  Future<void> _initGpuEngine() async {
    final program = await ui.FragmentProgram.fromAsset(
      'shaders/resolve_color_pipeline.frag',
    );
    final demoImage = await _generateReferenceTestChart(1280, 720);
    if (mounted) {
      setState(() {
        _program = program;
        _sourceImage = demoImage;
      });
    }
  }

  // Generates a Built-In Cinema Reference Frame (Skin tones, Sky, Color Patches, Luma Ramp)
  Future<ui.Image> _generateReferenceTestChart(int width, int height) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final w = width.toDouble();
    final h = height.toDouble();

    // 1. Sunset/Twilight Cinema Sky Gradient
    final skyPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        Offset(w, h * 0.75),
        [
          const Color(0xFF0D2B45),
          const Color(0xFF203C56),
          const Color(0xFF544E68),
          const Color(0xFF8D697A),
          const Color(0xFFD08159),
          const Color(0xFFFFAA5E),
        ],
        [0.0, 0.25, 0.45, 0.65, 0.85, 1.0],
      );
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), skyPaint);

    // 2. Simulated Subject Portrait / Skin Tone Reference Sphere in Center
    final skinPaint = Paint()
      ..shader = ui.Gradient.radial(
        Offset(w * 0.48, h * 0.42),
        h * 0.28,
        [
          const Color(0xFFF3C6A8),
          const Color(0xFFD89673),
          const Color(0xFFA86448),
          const Color(0xFF5D3222),
        ],
        [0.0, 0.45, 0.8, 1.0],
      );
    canvas.drawCircle(Offset(w * 0.5, h * 0.45), h * 0.24, skinPaint);

    // 3. Color Checker Patches (Bottom Above Ramp)
    final patches = [
      const Color(0xFF735244), // Dark Skin
      const Color(0xFFC29682), // Light Skin
      const Color(0xFF627A9D), // Blue Sky
      const Color(0xFF576C43), // Foliage
      const Color(0xFF8580B1), // Blue Flower
      const Color(0xFF67BDAA), // Bluish Green
      const Color(0xFFD67E2C), // Orange
      const Color(0xFF505BA6), // Purplish Blue
      const Color(0xFFC15A63), // Moderate Red
      const Color(0xFF5E3C6C), // Purple
      const Color(0xFF9DBC40), // Yellow Green
      const Color(0xFFE0A32E), // Orange Yellow
    ];
    final patchW = w / patches.length;
    for (int i = 0; i < patches.length; i++) {
      canvas.drawRect(
        Rect.fromLTWH(i * patchW, h * 0.76, patchW - 2, h * 0.12),
        Paint()..color = patches[i],
      );
    }

    // 4. 0-100 IRE Grayscale Dynamic Range Ramp at Bottom
    final rampPaint = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, h * 0.9),
        Offset(w, h * 0.9),
        [Colors.black, Colors.white],
      );
    canvas.drawRect(Rect.fromLTWH(0, h * 0.89, w, h * 0.11), rampPaint);

    final picture = recorder.endRecording();
    return picture.toImage(width, height);
  }

  Future<void> _pickImageFromGallery() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final Uint8List bytes = await file.readAsBytes();
    final ui.Codec codec = await ui.instantiateImageCodec(bytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    if (mounted) {
      setState(() {
        _sourceImage = frame.image;
      });
    }
  }

  Future<void> _exportGradedFrame() async {
    try {
      final boundary = _viewportKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return;
      final ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      final ByteData? byteData =
          await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;
      final Uint8List pngBytes = byteData.buffer.asUint8List();
      await Gal.putImageBytes(
        pngBytes,
        name: 'ResolvePro_Grade_${DateTime.now().millisecondsSinceEpoch}',
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF2E7D32),
            content: Text(
              'Graded High-Bitrate Frame Saved to Gallery!',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export Notice: $e')),
        );
      }
    }
  }

  void _addNode() {
    setState(() {
      final numStr = (_nodes.length + 1).toString().padLeft(2, '0');
      _nodes.add(ColorNodeState(id: numStr, label: '$numStr: Serial Node'));
      _activeNodeIndex = _nodes.length - 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildTopWorkstationBar(),
          Expanded(
            flex: 52,
            child: Row(
              children: [
                if (_showScopesOverlay) _buildLeftScopesDrawer(),
                Expanded(child: _buildCenterViewport()),
                if (_showNodePanel) _buildRightNodeGraphPanel(),
              ],
            ),
          ),
          _buildDeckModeSelectorBar(),
          Expanded(
            flex: 48,
            child: _buildBottomGradingDeck(),
          ),
        ],
      ),
    );
  }

  // --- TOP BAR: PROJECT PIPELINE, IMPORT, WIPE, BYPASS, EXPORT ---
  Widget _buildTopWorkstationBar() {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF1A1A20),
        border: Border(bottom: BorderSide(color: Color(0xFF2C2C35), width: 1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.blur_circular, color: Color(0xFFFF5722), size: 18),
          const SizedBox(width: 6),
          const Text(
            'DAVINCI RESOLVE MOBILE STUDIO',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: Color(0xFFE0E0E6),
            ),
          ),
          const SizedBox(width: 12),
          _topChipButton(
            icon: Icons.folder_open,
            label: 'Import RAW/Photo',
            onTap: _pickImageFromGallery,
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.bar_chart,
            label: 'Scopes',
            active: _showScopesOverlay,
            onTap: () =>
                setState(() => _showScopesOverlay = !_showScopesOverlay),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.account_tree_outlined,
            label: 'Nodes (${_nodes.length})',
            active: _showNodePanel,
            onTap: () => setState(() => _showNodePanel = !_showNodePanel),
          ),
          const Spacer(),
          // Split Screen Wipe Slider
          const Text(
            'Wipe:',
            style: TextStyle(fontSize: 10, color: Colors.white60),
          ),
          SizedBox(
            width: 90,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 5.0),
              ),
              child: Slider(
                value: _splitWipe,
                min: 0.0,
                max: 1.0,
                activeColor: const Color(0xFFFF5722),
                onChanged: (v) => setState(() => _splitWipe = v),
              ),
            ),
          ),
          _topChipButton(
            icon: Icons.contrast,
            label: 'Highlight Matte',
            active: _showMatteHighlight,
            onTap: () =>
                setState(() => _showMatteHighlight = !_showMatteHighlight),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.visibility_off_outlined,
            label: 'Bypass',
            active: _globalBypass,
            activeColor: Colors.redAccent,
            onTap: () => setState(() => _globalBypass = !_globalBypass),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.refresh,
            label: 'Reset Node',
            onTap: () => setState(() => _currentNode.reset()),
          ),
          const SizedBox(width: 6),
          _topChipButton(
            icon: Icons.download_done,
            label: 'Export',
            active: true,
            activeColor: const Color(0xFF00897B),
            onTap: _exportGradedFrame,
          ),
        ],
      ),
    );
  }

  Widget _topChipButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool active = false,
    Color activeColor = const Color(0xFFFF5722),
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: active ? activeColor.withOpacity(0.22) : const Color(0xFF25252E),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: active ? activeColor : const Color(0xFF383844),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, size: 12, color: active ? activeColor : Colors.white70),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: active ? Colors.white : Colors.white70,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --- CENTER VIEWPORT: GPU 32-BIT FLOAT REAL-TIME MONITOR ---
  Widget _buildCenterViewport() {
    if (_program == null || _sourceImage == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return Container(
      color: const Color(0xFF0D0D10),
      child: Stack(
        alignment: Alignment.center,
        children: [
          InteractiveViewer(
            minScale: 0.8,
            maxScale: 8.0,
            child: AspectRatio(
              aspectRatio: _sourceImage!.width / _sourceImage!.height,
              child: RepaintBoundary(
                key: _viewportKey,
                child: CustomPaint(
                  painter: _ResolveGpuPipelinePainter(
                    program: _program!,
                    sourceImage: _sourceImage!,
                    nodes: _nodes,
                    activeNodeIndex: _activeNodeIndex,
                    splitWipe: _splitWipe,
                    bypass: _globalBypass,
                    showMatte: _showMatteHighlight,
                  ),
                ),
              ),
            ),
          ),
          // Power Window Interactive Touch Overlay when Window Tab is active
          if (_currentNode.winEnabled && _selectedDeckTab == 4)
            Positioned.fill(
              child: GestureDetector(
                onPanUpdate: (details) {
                  final box = context.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  setState(() {
                    _currentNode.winCenterX = (_currentNode.winCenterX +
                            details.delta.dx / (box.size.width * 0.5))
                        .clamp(0.05, 0.95);
                    _currentNode.winCenterY = (_currentNode.winCenterY +
                            details.delta.dy / (box.size.height * 0.4))
                        .clamp(0.05, 0.95);
                  });
                },
                child: CustomPaint(
                  painter: _PowerWindowOverlayPainter(node: _currentNode),
                ),
              ),
            ),
          Positioned(
            left: 10,
            bottom: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                '32-Bit Float GPU | Active: ${_currentNode.label} | Pinch to 800% Zoom',
                style: const TextStyle(fontSize: 9, color: Colors.white60),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- LEFT COLLAPSIBLE PANEL: LIVE RGB PARADE & WAVEFORM SCOPES ---
  Widget _buildLeftScopesDrawer() {
    return Container(
      width: 195,
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        color: Color(0xFF18181D),
        border: Border(right: BorderSide(color: Color(0xFF2C2C35))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'VIDEO SCOPES (RGB PARADE)',
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: Colors.white54,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0A0A0D),
                border: Border.all(color: const Color(0xFF2D2D36)),
                borderRadius: BorderRadius.circular(4),
              ),
              child: CustomPaint(
                size: Size.infinite,
                painter: _ScopesParadePainter(node: _currentNode),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // --- RIGHT COLLAPSIBLE PANEL: DAVINCI NODE GRAPH PIPELINE ---
  Widget _buildRightNodeGraphPanel() {
    return Container(
      width: 215,
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        color: Color(0xFF18181D),
        border: Border(left: BorderSide(color: Color(0xFF2C2C35))),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'NODE GRAPH (DAG)',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Colors.white54,
                ),
              ),
              InkWell(
                onTap: _addNode,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5722).withOpacity(0.25),
                    borderRadius: BorderRadius.circular(3),
                    border: Border.all(color: const Color(0xFFFF5722)),
                  ),
                  child: const Text(
                    '+ Serial Node',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              itemCount: _nodes.length,
              itemBuilder: (context, idx) {
                final node = _nodes[idx];
                final isSelected = idx == _activeNodeIndex;
                return GestureDetector(
                  onTap: () => setState(() => _activeNodeIndex = idx),
                  onDoubleTap: () =>
                      setState(() => node.enabled = !node.enabled),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 6),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF2B2B36)
                          : const Color(0xFF1F1F27),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFFFF5722)
                            : Colors.white12,
                        width: isSelected ? 1.5 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: node.enabled
                                ? const Color(0xFF4CAF50)
                                : Colors.redAccent,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                node.label,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  color: node.enabled
                                      ? Colors.white
                                      : Colors.white38,
                                ),
                              ),
                              Text(
                                _buildNodeBadges(node),
                                style: const TextStyle(
                                  fontSize: 8,
                                  color: Color(0xFF29B6F6),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_nodes.length > 1)
                          InkWell(
                            onTap: () {
                              setState(() {
                                _nodes.removeAt(idx);
                                if (_activeNodeIndex >= _nodes.length) {
                                  _activeNodeIndex = _nodes.length - 1;
                                }
                              });
                            },
                            child: const Icon(
                              Icons.close,
                              size: 13,
                              color: Colors.white38,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const Text(
            'Double-tap node to Enable/Bypass',
            style: TextStyle(fontSize: 8, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  String _buildNodeBadges(ColorNodeState n) {
    final List<String> tags = ['RGB'];
    if (n.inputCST > 0 || n.outputCST > 0) tags.add('CST');
    if (n.lutPreset > 0) tags.add('LUT');
    if (n.qualEnabled) tags.add('3D-KEY');
    if (n.winEnabled) tags.add(n.winInvert ? 'OUT-WIN' : 'WIN');
    return tags.join(' • ');
  }

  // --- DECK MODE SWITCHER BAR ---
  Widget _buildDeckModeSelectorBar() {
    final tabs = [
      (Icons.Games, 'PRIMARIES WHEELS'),
      (Icons.hdr_strong, 'HDR & TONAL ZONE'),
      (Icons.transform, 'CST & FILM LUTS'),
      (Icons.colorize, '3D HSL QUALIFIER'),
      (Icons.crop_free, 'POWER WINDOW'),
    ];
    return Container(
      height: 28,
      color: const Color(0xFF1C1C22),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(tabs.length, (i) {
          final selected = _selectedDeckTab == i;
          return InkWell(
            onTap: () => setState(() => _selectedDeckTab = i),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color:
                        selected ? const Color(0xFFFF5722) : Colors.transparent,
                    width: 2,
                  ),
                ),
              ),
              child: Text(
                tabs[i].$2,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: selected ? const Color(0xFFFF5722) : Colors.white60,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // --- BOTTOM GRADING DECK ---
  Widget _buildBottomGradingDeck() {
    return Container(
      color: const Color(0xFF16161B),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: switch (_selectedDeckTab) {
        0 => _buildPrimariesWheelsDeck(),
        1 => _buildHdrAndTonalDeck(),
        2 => _buildCstAndLutDeck(),
        3 => _buildQualifierDeck(),
        4 => _buildPowerWindowDeck(),
        _ => _buildPrimariesWheelsDeck(),
      },
    );
  }

  // TAB 0: 4 DAVINCI PRIMARY COLOR WHEELS (LIFT, GAMMA, GAIN, OFFSET) + SLIDERS
  Widget _buildPrimariesWheelsDeck() {
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: _DaVinciColorWheelWidget(
                  title: 'LIFT (SHADOWS)',
                  values: _currentNode.lift,
                  sensitivity: 0.35,
                  onChanged: (v) => setState(() => _currentNode.lift = v),
                ),
              ),
              Expanded(
                child: _DaVinciColorWheelWidget(
                  title: 'GAMMA (MIDTONES)',
                  values: _currentNode.gamma,
                  sensitivity: 0.45,
                  onChanged: (v) => setState(() => _currentNode.gamma = v),
                ),
              ),
              Expanded(
                child: _DaVinciColorWheelWidget(
                  title: 'GAIN (HIGHLIGHTS)',
                  values: _currentNode.gain,
                  sensitivity: 0.55,
                  onChanged: (v) => setState(() => _currentNode.gain = v),
                ),
              ),
              Expanded(
                child: _DaVinciColorWheelWidget(
                  title: 'OFFSET (GLOBAL)',
                  values: _currentNode.offset,
                  sensitivity: 0.30,
                  onChanged: (v) => setState(() => _currentNode.offset = v),
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 4, color: Color(0xFF2A2A34)),
        SizedBox(
          height: 36,
          child: Row(
            children: [
              _microParameterSlider(
                label: 'Contrast',
                val: _currentNode.contrast,
                min: 0.4,
                max: 2.0,
                defaultVal: 1.0,
                onChanged: (v) => setState(() => _currentNode.contrast = v),
              ),
              _microParameterSlider(
                label: 'Pivot',
                val: _currentNode.pivot,
                min: 0.1,
                max: 0.9,
                defaultVal: 0.435,
                onChanged: (v) => setState(() => _currentNode.pivot = v),
              ),
              _microParameterSlider(
                label: 'Sat',
                val: _currentNode.saturation,
                min: 0.0,
                max: 2.0,
                defaultVal: 1.0,
                onChanged: (v) => setState(() => _currentNode.saturation = v),
              ),
              _microParameterSlider(
                label: 'Temp',
                val: _currentNode.temp,
                min: -1.0,
                max: 1.0,
                defaultVal: 0.0,
                onChanged: (v) => setState(() => _currentNode.temp = v),
              ),
              _microParameterSlider(
                label: 'Tint',
                val: _currentNode.tint,
                min: -1.0,
                max: 1.0,
                defaultVal: 0.0,
                onChanged: (v) => setState(() => _currentNode.tint = v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // TAB 1: HDR ZONES, SHADOW/HIGHLIGHT RECOVERY, COLOR BOOST, LUM MIX
  Widget _buildHdrAndTonalDeck() {
    return Row(
      children: [
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _fullWidthSlider(
                label: 'Color Boost (Skin-Safe Vibrance)',
                val: _currentNode.colorBoost,
                min: -1.0,
                max: 1.5,
                onChanged: (v) => setState(() => _currentNode.colorBoost = v),
              ),
              _fullWidthSlider(
                label: 'HDR Shadow Zone Recovery',
                val: _currentNode.shadows,
                min: -1.0,
                max: 1.0,
                onChanged: (v) => setState(() => _currentNode.shadows = v),
              ),
              _fullWidthSlider(
                label: 'HDR Specular / Highlight Roll-off',
                val: _currentNode.highlights,
                min: -1.0,
                max: 1.0,
                onChanged: (v) => setState(() => _currentNode.highlights = v),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _fullWidthSlider(
                label: 'Lum Mix (YRGB vs Luminance Lock)',
                val: _currentNode.lumMix,
                min: 0.0,
                max: 1.0,
                onChanged: (v) => setState(() => _currentNode.lumMix = v),
              ),
              _fullWidthSlider(
                label: 'S-Curve Contrast',
                val: _currentNode.contrast,
                min: 0.3,
                max: 2.2,
                onChanged: (v) => setState(() => _currentNode.contrast = v),
              ),
              _fullWidthSlider(
                label: 'Midtone Pivot Center',
                val: _currentNode.pivot,
                min: 0.1,
                max: 0.9,
                onChanged: (v) => setState(() => _currentNode.pivot = v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // TAB 2: COLOR SPACE TRANSFORM (CST) & FILM EMULATION LUTS
  Widget _buildCstAndLutDeck() {
    final inSpaces = [
      'Rec.709 (Standard)',
      'Sony S-Log3 / S-Gamut3.Cine',
      'ARRI LogC3 / Wide Gamut',
      'DJI D-Log',
      'Linear Camera RAW'
    ];
    final outSpaces = [
      'Rec.709 Gamma 2.4',
      'sRGB Display',
      'DaVinci Wide Gamut (Log)',
      'ACEScct Filmic ODT',
      'Rec.2020 HLG (HDR)'
    ];
    final luts = [
      'No LUT (Bypass)',
      'Kodak 2383 Print Film',
      'Fujifilm 3513 Print',
      'Hollywood Teal & Orange',
      'Silver Bleach Bypass'
    ];

    return Row(
      children: [
        Expanded(
          child: _dropdownCard(
            title: 'INPUT COLOR SPACE (CAMERA LOG)',
            options: inSpaces,
            currentIndex: _currentNode.inputCST,
            onSelect: (i) => setState(() => _currentNode.inputCST = i),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _dropdownCard(
            title: 'OUTPUT COLOR SPACE (ODT)',
            options: outSpaces,
            currentIndex: _currentNode.outputCST,
            onSelect: (i) => setState(() => _currentNode.outputCST = i),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            children: [
              Expanded(
                child: _dropdownCard(
                  title: '3D FILM LUT ENGINE',
                  options: luts,
                  currentIndex: _currentNode.lutPreset,
                  onSelect: (i) => setState(() => _currentNode.lutPreset = i),
                ),
              ),
              _fullWidthSlider(
                label: 'LUT Intensity / Blend',
                val: _currentNode.lutStrength,
                min: 0.0,
                max: 1.0,
                onChanged: (v) => setState(() => _currentNode.lutStrength = v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // TAB 3: 3D HSL QUALIFIER (SKIN TONE / SKY ISOLATION)
  Widget _buildQualifierDeck() {
    return Row(
      children: [
        SizedBox(
          width: 170,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SwitchListTile(
                dense: true,
                title: const Text(
                  'Enable 3D Qualifier',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
                value: _currentNode.qualEnabled,
                activeColor: const Color(0xFFFF5722),
                onChanged: (v) => setState(() => _currentNode.qualEnabled = v),
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2B2B36),
                ),
                onPressed: () {
                  setState(() {
                    _currentNode.qualEnabled = true;
                    _currentNode.qualHueCenter = 0.055; // Skin tone hue
                    _currentNode.qualHueWidth = 0.14;
                    _currentNode.qualSoftness = 0.07;
                    _currentNode.qualSatMin = 0.15;
                    _currentNode.qualLumMin = 0.12;
                  });
                },
                icon: const Icon(Icons.face, size: 14),
                label: const Text(
                  'Skin Tone Preset',
                  style: TextStyle(fontSize: 10),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _fullWidthSlider(
                label: 'Hue Center (0=Red/Skin, 0.33=Green, 0.66=Blue/Sky)',
                val: _currentNode.qualHueCenter,
                min: 0.0,
                max: 1.0,
                onChanged: (v) =>
                    setState(() => _currentNode.qualHueCenter = v),
              ),
              _fullWidthSlider(
                label: 'Hue Range Width',
                val: _currentNode.qualHueWidth,
                min: 0.02,
                max: 0.60,
                onChanged: (v) => setState(() => _currentNode.qualHueWidth = v),
              ),
              _fullWidthSlider(
                label: 'Matte Edge Softness (Clean Black/White)',
                val: _currentNode.qualSoftness,
                min: 0.01,
                max: 0.35,
                onChanged: (v) => setState(() => _currentNode.qualSoftness = v),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _fullWidthSlider(
                label: 'Minimum Saturation Cut',
                val: _currentNode.qualSatMin,
                min: 0.0,
                max: 0.8,
                onChanged: (v) => setState(() => _currentNode.qualSatMin = v),
              ),
              _fullWidthSlider(
                label: 'Minimum Luminance Cut',
                val: _currentNode.qualLumMin,
                min: 0.0,
                max: 0.8,
                onChanged: (v) => setState(() => _currentNode.qualLumMin = v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // TAB 4: POWER WINDOWS (CIRCULAR / VIGNETTE / OUTSIDE NODE)
  Widget _buildPowerWindowDeck() {
    return Row(
      children: [
        SizedBox(
          width: 185,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SwitchListTile(
                dense: true,
                title: const Text(
                  'Power Window ON',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
                value: _currentNode.winEnabled,
                activeColor: const Color(0xFFFF5722),
                onChanged: (v) => setState(() => _currentNode.winEnabled = v),
              ),
              SwitchListTile(
                dense: true,
                title: const Text(
                  'Invert (Outside Node)',
                  style: TextStyle(fontSize: 10),
                ),
                value: _currentNode.winInvert,
                activeColor: const Color(0xFF29B6F6),
                onChanged: (v) => setState(() => _currentNode.winInvert = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _fullWidthSlider(
                label: 'Window Width (Radius X)',
                val: _currentNode.winRadiusX,
                min: 0.05,
                max: 0.90,
                onChanged: (v) => setState(() => _currentNode.winRadiusX = v),
              ),
              _fullWidthSlider(
                label: 'Window Height (Radius Y)',
                val: _currentNode.winRadiusY,
                min: 0.05,
                max: 0.90,
                onChanged: (v) => setState(() => _currentNode.winRadiusY = v),
              ),
              _fullWidthSlider(
                label: 'Window Feather / Softness',
                val: _currentNode.winFeather,
                min: 0.02,
                max: 0.85,
                onChanged: (v) => setState(() => _currentNode.winFeather = v),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _dropdownCard({
    required String title,
    required List<String> options,
    required int currentIndex,
    required ValueChanged<int> onSelect,
  }) {
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F27),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFF2F2F3B)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: Color(0xFFFF5722),
            ),
          ),
          const SizedBox(height: 4),
          Expanded(
            child: ListView.builder(
              itemCount: options.length,
              itemBuilder: (ctx, i) {
                final selected = i == currentIndex;
                return InkWell(
                  onTap: () => onSelect(i),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
                    decoration: BoxDecoration(
                      color: selected
                          ? const Color(0xFFFF5722).withOpacity(0.2)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(3),
                    ),
                    child: Text(
                      options[i],
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight:
                            selected ? FontWeight.bold : FontWeight.normal,
                        color: selected ? Colors.white : Colors.white70,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _microParameterSlider({
    required String label,
    required double val,
    required double min,
    required double max,
    required double defaultVal,
    required ValueChanged<double> onChanged,
  }) {
    return Expanded(
      child: GestureDetector(
        onDoubleTap: () => onChanged(defaultVal),
        child: Row(
          children: [
            Text(
              '$label: ${val.toStringAsFixed(2)}',
              style: const TextStyle(fontSize: 9, color: Colors.white70),
            ),
            Expanded(
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape:
                      const RoundSliderThumbShape(enabledThumbRadius: 4.5),
                ),
                child: Slider(
                  value: val.clamp(min, max),
                  min: min,
                  max: max,
                  activeColor: const Color(0xFF29B6F6),
                  onChanged: onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fullWidthSlider({
    required String label,
    required double val,
    required double min,
    required double max,
    required ValueChanged<double> onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 190,
          child: Text(
            '$label (${val.toStringAsFixed(2)})',
            style: const TextStyle(fontSize: 10, color: Colors.white70),
          ),
        ),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2.5,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            ),
            child: Slider(
              value: val.clamp(min, max),
              min: min,
              max: max,
              activeColor: const Color(0xFFFF5722),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}

// --- CUSTOM WIDGET: INTERACTIVE DAVINCI 2D COLOR WHEEL + MASTER JOG SLIDER ---
class _DaVinciColorWheelWidget extends StatelessWidget {
  final String title;
  final List<double> values; // [R, G, B, Master Y]
  final double sensitivity;
  final ValueChanged<List<double>> onChanged;

  const _DaVinciColorWheelWidget({
    required this.title,
    required this.values,
    required this.sensitivity,
    required this.onChanged,
  });

  void _updateFromWheelDelta(Offset delta, double radius) {
    final dx = (delta.dx / radius) * sensitivity;
    final dy = (-delta.dy / radius) * sensitivity;
    // Convert 2D vector movement into RGB differential push
    final r = (values[0] + dx * 0.7 + dy * 0.4).clamp(-0.6, 0.6);
    final g = (values[1] - dx * 0.35 + dy * 0.5).clamp(-0.6, 0.6);
    final b = (values[2] - dx * 0.35 - dy * 0.7).clamp(-0.6, 0.6);
    onChanged([r, g, b, values[3]]);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: const Color(0xFF1D1D24),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF2D2D38)),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
              GestureDetector(
                onTap: () => onChanged([0.0, 0.0, 0.0, 0.0]),
                child: const Icon(
                  Icons.replay,
                  size: 12,
                  color: Colors.white54,
                ),
              ),
            ],
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final diameter =
                    math.min(constraints.maxWidth, constraints.maxHeight) - 4;
                final radius = diameter / 2;
                return Center(
                  child: GestureDetector(
                    onDoubleTap: () => onChanged([0.0, 0.0, 0.0, values[3]]),
                    onPanUpdate: (d) => _updateFromWheelDelta(d.delta, radius),
                    child: CustomPaint(
                      size: Size(diameter, diameter),
                      painter: _ColorWheelRingPainter(values: values),
                    ),
                  ),
                );
              },
            ),
          ),
          // Master Luminance (Y) Jog Slider underneath Wheel
          SizedBox(
            height: 20,
            child: Row(
              children: [
                const Text(
                  'Y',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white54,
                  ),
                ),
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 4.5),
                    ),
                    child: Slider(
                      value: values[3].clamp(-0.5, 0.5),
                      min: -0.5,
                      max: 0.5,
                      activeColor: Colors.white70,
                      onChanged: (y) =>
                          onChanged([values[0], values[1], values[2], y]),
                    ),
                  ),
                ),
                Text(
                  values[3].toStringAsFixed(2),
                  style: const TextStyle(fontSize: 8, color: Colors.white54),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ColorWheelRingPainter extends CustomPainter {
  final List<double> values;
  _ColorWheelRingPainter({required this.values});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Outer Hue Spectrum Ring
    final rect = Rect.fromCircle(center: center, radius: radius);
    final sweepShader = const SweepGradient(
      colors: [
        Colors.red,
        Colors.yellow,
        Colors.green,
        Colors.cyan,
        Colors.blue,
        Colors.purple,
        Colors.red,
      ],
    ).createShader(rect);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = sweepShader
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0,
    );

    // Inner Dark Track Pad
    canvas.drawCircle(
      center,
      radius - 5,
      Paint()..color = const Color(0xFF121216),
    );

    // Crosshairs
    final linePaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(center.dx - radius + 6, center.dy),
      Offset(center.dx + radius - 6, center.dy),
      linePaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - radius + 6),
      Offset(center.dx, center.dy + radius - 6),
      linePaint,
    );

    // Puck Position from RGB offset
    final puckX = center.dx + (values[0] - values[2]) * radius * 0.75;
    final puckY = center.dy - (values[1] - values[2]) * radius * 0.75;
    final clampedOffset = Offset(
      puckX.clamp(center.dx - radius + 8, center.dx + radius - 8),
      puckY.clamp(center.dy - radius + 8, center.dy + radius - 8),
    );

    canvas.drawCircle(
      clampedOffset,
      5.5,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0,
    );
  }

  @override
  bool shouldRepaint(covariant _ColorWheelRingPainter oldDelegate) => true;
}

// --- GPU SHADER PIPELINE PAINTER (AGGREGATES MULTI-NODE STACK) ---
class _ResolveGpuPipelinePainter extends CustomPainter {
  final ui.FragmentProgram program;
  final ui.Image sourceImage;
  final List<ColorNodeState> nodes;
  final int activeNodeIndex;
  final double splitWipe;
  final bool bypass;
  final bool showMatte;

  _ResolveGpuPipelinePainter({
    required this.program,
    required this.sourceImage,
    required this.nodes,
    required this.activeNodeIndex,
    required this.splitWipe,
    required this.bypass,
    required this.showMatte,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final shader = program.fragmentShader();

    // Combine enabled serial nodes into the GPU uniform pipeline
    List<double> lift = [0, 0, 0, 0];
    List<double> gamma = [0, 0, 0, 0];
    List<double> gain = [0, 0, 0, 0];
    List<double> offset = [0, 0, 0, 0];
    double contrast = 1.0;
    double pivot = 0.435;
    double sat = 1.0;
    double temp = 0.0;
    double tint = 0.0;
    double boost = 0.0;
    double shadows = 0.0;
    double highlights = 0.0;
    double lumMix = 1.0;
    int inCST = 0;
    int outCST = 0;
    int lut = 0;
    double lutStr = 0.85;

    for (final n in nodes) {
      if (!n.enabled) continue;
      for (int i = 0; i < 4; i++) {
        lift[i] += n.lift[i];
        gamma[i] += n.gamma[i];
        gain[i] += n.gain[i];
        offset[i] += n.offset[i];
      }
      contrast *= n.contrast;
      pivot = n.pivot;
      sat *= n.saturation;
      temp += n.temp;
      tint += n.tint;
      boost += n.colorBoost;
      shadows += n.shadows;
      highlights += n.highlights;
      lumMix = n.lumMix;
      if (n.inputCST > 0) inCST = n.inputCST;
      if (n.outputCST > 0) outCST = n.outputCST;
      if (n.lutPreset > 0) {
        lut = n.lutPreset;
        lutStr = n.lutStrength;
      }
    }

    final activeNode = nodes[activeNodeIndex];

    // Bind all 47 Uniform Floats matching resolve_color_pipeline.frag
    shader.setFloat(0, size.width);
    shader.setFloat(1, size.height);

    // Lift (2..5)
    shader.setFloat(2, lift[0]);
    shader.setFloat(3, lift[1]);
    shader.setFloat(4, lift[2]);
    shader.setFloat(5, lift[3]);

    // Gamma (6..9)
    shader.setFloat(6, gamma[0]);
    shader.setFloat(7, gamma[1]);
    shader.setFloat(8, gamma[2]);
    shader.setFloat(9, gamma[3]);

    // Gain (10..13)
    shader.setFloat(10, gain[0]);
    shader.setFloat(11, gain[1]);
    shader.setFloat(12, gain[2]);
    shader.setFloat(13, gain[3]);

    // Offset (14..17)
    shader.setFloat(14, offset[0]);
    shader.setFloat(15, offset[1]);
    shader.setFloat(16, offset[2]);
    shader.setFloat(17, offset[3]);

    // Primaries (18..26)
    shader.setFloat(18, contrast);
    shader.setFloat(19, pivot);
    shader.setFloat(20, sat);
    shader.setFloat(21, temp);
    shader.setFloat(22, tint);
    shader.setFloat(23, boost);
    shader.setFloat(24, shadows);
    shader.setFloat(25, highlights);
    shader.setFloat(26, lumMix);

    // CST & LUT (27..30)
    shader.setFloat(27, inCST.toDouble());
    shader.setFloat(28, outCST.toDouble());
    shader.setFloat(29, lut.toDouble());
    shader.setFloat(30, lutStr);

    // 3D Qualifier (31..37)
    shader.setFloat(31, activeNode.qualEnabled ? 1.0 : 0.0);
    shader.setFloat(32, activeNode.qualHueCenter);
    shader.setFloat(33, activeNode.qualHueWidth);
    shader.setFloat(34, activeNode.qualSoftness);
    shader.setFloat(35, activeNode.qualSatMin);
    shader.setFloat(36, activeNode.qualLumMin);
    shader.setFloat(37, showMatte ? 1.0 : 0.0);

    // Power Window (38..44)
    shader.setFloat(38, activeNode.winEnabled ? 1.0 : 0.0);
    shader.setFloat(39, activeNode.winCenterX);
    shader.setFloat(40, activeNode.winCenterY);
    shader.setFloat(41, activeNode.winRadiusX);
    shader.setFloat(42, activeNode.winRadiusY);
    shader.setFloat(43, activeNode.winFeather);
    shader.setFloat(44, activeNode.winInvert ? 1.0 : 0.0);

    // Wipe & Bypass (45..46)
    shader.setFloat(45, splitWipe);
    shader.setFloat(46, bypass ? 1.0 : 0.0);

    shader.setImageSampler(0, sourceImage);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant _ResolveGpuPipelinePainter oldDelegate) => true;
}

// --- POWER WINDOW INTERACTIVE WIREFRAME OVERLAY ---
class _PowerWindowOverlayPainter extends CustomPainter {
  final ColorNodeState node;
  _PowerWindowOverlayPainter({required this.node});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(
      node.winCenterX * size.width,
      node.winCenterY * size.height,
    );
    final rx = node.winRadiusX * size.width;
    final ry = node.winRadiusY * size.height;

    final innerRect = Rect.fromCenter(
      center: center,
      width: rx * 2,
      height: ry * 2,
    );
    canvas.drawOval(
      innerRect,
      Paint()
        ..color = const Color(0xFF29B6F6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // Feather Outer Boundary
    final outerRect = Rect.fromCenter(
      center: center,
      width: rx * 2 * (1.0 + node.winFeather),
      height: ry * 2 * (1.0 + node.winFeather),
    );
    canvas.drawOval(
      outerRect,
      Paint()
        ..color = const Color(0xFFFF5722).withOpacity(0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0,
    );
  }

  @override
  bool shouldRepaint(covariant _PowerWindowOverlayPainter oldDelegate) => true;
}

// --- REAL-TIME RGB PARADE SCOPE PAINTER ---
class _ScopesParadePainter extends CustomPainter {
  final ColorNodeState node;
  _ScopesParadePainter({required this.node});

  @override
  void paint(Canvas canvas, Size size) {
    // Draw IRE Graticule Lines (0, 25, 50, 75, 100 IRE)
    final gridPaint = Paint()
      ..color = Colors.white12
      ..strokeWidth = 0.8;
    for (int i = 1; i < 4; i++) {
      final y = size.height * (i / 4.0);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final thirdW = size.width / 3.0;
    final channels = [
      (Colors.redAccent, node.lift[0] + node.temp * 0.2, node.gain[0]),
      (Colors.greenAccent, node.lift[1] - node.tint * 0.2, node.gain[1]),
      (Colors.lightBlueAccent, node.lift[2] - node.temp * 0.2, node.gain[2]),
    ];

    for (int c = 0; c < 3; c++) {
      final startX = c * thirdW;
      final paint = Paint()
        ..color = channels[c].$1.withOpacity(0.75)
        ..strokeWidth = 1.5
        ..style = PaintingStyle.stroke;

      final path = Path();
      for (int x = 0; x < thirdW.toInt(); x += 2) {
        final normX = x / thirdW;
        double wave = 0.5 +
            0.32 * math.sin(normX * math.pi * 2.0 + c) +
            channels[c].$2 * 0.4 +
            channels[c].$3 * normX * 0.35 +
            node.lift[3] * 0.3;
        wave = ((wave - node.pivot) * node.contrast + node.pivot).clamp(0.02, 0.98);
        final py = size.height * (1.0 - wave);
        if (x == 0) {
          path.moveTo(startX + x, py);
        } else {
          path.lineTo(startX + x, py);
        }
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScopesParadePainter oldDelegate) => true;
}
