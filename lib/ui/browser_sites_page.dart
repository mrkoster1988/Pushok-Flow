import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

class BrowserSitesPage extends StatefulWidget {
  const BrowserSitesPage({super.key});
  @override
  State<BrowserSitesPage> createState() => _BrowserSitesPageState();
}

class _BrowserSitesPageState extends State<BrowserSitesPage> {
  static const channel = MethodChannel('shop.pushok.flow/browser_routes');
  Map<String,String> names = {};
  Set<String> selected = {};
  String? error;
  bool available = true;
  bool enabled = false;
  bool busy = true;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final data = await channel.invokeMapMethod<String,dynamic>('read');
      if (data == null) throw const FormatException();
      if (mounted) setState(() {
        names = Map<String,String>.from(data['names'] as Map);
        selected = Set<String>.from(data['selected'] as List);
        available = data['available'] == true;
        enabled = data['enabled'] == true; busy = false;
      });
    } catch (_) { if (mounted) setState(() {error='Не удалось загрузить настройки сайтов.';busy=false;}); }
  }

  Future<void> _change(String domain, bool enabled) async {
    final next = Set<String>.of(selected);
    if (enabled) { next.add(domain); } else { next.remove(domain); }
    setState(() { busy=true;error=null; });
    try {
      final saved = await channel.invokeMethod<bool>('set',next.toList());
      if (saved != true) throw const FormatException();
      if (mounted) setState(() => selected=next);
    } catch (_) { if (mounted) setState(() => error='Не удалось сохранить выбор.'); }
    finally { if (mounted) setState(() => busy=false); }
  }

  Future<void> _setEnabled(bool value) async {
    setState(() { busy=true;error=null; });
    try {
      final saved = await channel.invokeMethod<bool>('setEnabled',value);
      if (saved != true) throw const FormatException();
      if (mounted) setState(() => enabled=value);
    } catch (_) { if (mounted) setState(() => error='Не удалось сохранить настройку.'); }
    finally { if (mounted) setState(() => busy=false); }
  }

  @override
  Widget build(BuildContext context) => ListView(children: [
    const Text('Сайты напрямую',style:TextStyle(fontSize:20,fontWeight:FontWeight.w700)),
    const SizedBox(height:8),
    Text(available ? 'Дополнительный режим использует системный HTTP-прокси Android. Если сайты перестали открываться, выключите его. Настройки отдельных приложений не меняются. После изменений переподключите Flow.'
        : 'Для маршрутов сайтов нужен Android 10 или новее.'),
    if(error!=null) Text(error!),
    if(busy && names.isEmpty) const LinearProgressIndicator(),
    if(available) SwitchListTile(key: const Key('browser_proxy_enabled'),title:const Text('Включить маршруты сайтов'),subtitle:const Text('По умолчанию выключено · обычный WireGuard'),value:enabled,onChanged:busy?null:_setEnabled),
    if(available) for(final site in names.entries)
      SwitchListTile(title:Text(site.value),subtitle:Text(site.key),
        value:selected.contains(site.key),onChanged:busy?null:(v)=>_change(site.key,v)),
  ]);
}
