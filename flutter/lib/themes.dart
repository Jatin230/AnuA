import 'package:flutter/material.dart';
import 'package:flutter_hbb/desktop/widgets/tabbar_widget.dart';
import 'package:flutter_hbb/common.dart';

class AnuvadiniThemes {
  static final ColorThemeExtension cyberProxyColors = ColorThemeExtension(
    border: const Color(0xFF00FFCC),
    border2: const Color(0xFF00E5B8),
    border3: const Color(0x7700FFCC),
    highlight: const Color(0xFF003322),
    drag_indicator: const Color(0xFF00FFCC),
    shadow: const Color(0xFF000000),
    errorBannerBg: const Color(0xFF330000),
    me: const Color(0xFF00FFCC),
    toastBg: const Color(0xFF002222),
    toastText: const Color(0xFF00FFCC),
    divider: const Color(0xFF00FFCC).withOpacity(0.5),
  );

  static final ColorThemeExtension nordicFrostColors = ColorThemeExtension(
    border: const Color(0xFFD8DEE9),
    border2: const Color(0xFFE5E9F0),
    border3: const Color(0xFFECEFF4),
    highlight: const Color(0xFFE5E9F0),
    drag_indicator: const Color(0xFF81A1C1),
    shadow: const Color(0xFFB48EAD),
    errorBannerBg: const Color(0xFFBF616A),
    me: const Color(0xFF88C0D0),
    toastBg: const Color(0xFF4C566A),
    toastText: const Color(0xFFECEFF4),
    divider: const Color(0xFFD8DEE9),
  );

  static final ColorThemeExtension legacyConsoleColors = ColorThemeExtension(
    border: const Color(0xFF00FF00),
    border2: const Color(0xFF00AA00),
    border3: const Color(0xFF005500),
    highlight: const Color(0xFF002200),
    drag_indicator: const Color(0xFF00FF00),
    shadow: Colors.black,
    errorBannerBg: const Color(0xFF550000),
    me: const Color(0xFF00FF00),
    toastBg: Colors.black,
    toastText: const Color(0xFF00FF00),
    divider: const Color(0xFF00AA00),
  );

  static final ColorThemeExtension obsidianNightColors = ColorThemeExtension(
    border: const Color(0xFF333333),
    border2: const Color(0xFF444444),
    border3: const Color(0xFF222222),
    highlight: const Color(0xFF111111),
    drag_indicator: const Color(0xFFFFFFFF),
    shadow: Colors.black,
    errorBannerBg: const Color(0xFF660000),
    me: const Color(0xFFEEEEEE),
    toastBg: const Color(0xFF1A1A1A),
    toastText: Colors.white,
    divider: const Color(0xFF333333),
  );

  static final ColorThemeExtension sakuraBloomColors = ColorThemeExtension(
    border: const Color(0xFFE91E8C),
    border2: const Color(0xFFF48FB1),
    border3: const Color(0xFFFCE4EC),
    highlight: const Color(0xFFFFF0F5),
    drag_indicator: const Color(0xFFE91E8C),
    shadow: const Color(0xFFD81B60).withOpacity(0.2),
    errorBannerBg: const Color(0xFFFFCDD2),
    me: const Color(0xFFE91E8C),
    toastBg: const Color(0xFFAD1457),
    toastText: Colors.white,
    divider: const Color(0xFFF48FB1),
  );

  static ThemeData getThemeData(String name) {
    switch (name) {
      case 'cyber_proxy':
        return cyberProxy;
      case 'legacy_console':
        return legacyConsole;
      case 'obsidian_night':
        return obsidianNight;
      case 'sakura_bloom':
        return sakuraBloom;
      case 'nordic_frost':
      default:
        return nordicFrost;
    }
  }

  static ThemeData get cyberProxy {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0B0E14),
      dialogBackgroundColor: const Color(0xFF151A22),
      cardColor: const Color(0xFF151A22),
      hoverColor: const Color(0xFF004433),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF0B0E14),
        foregroundColor: Color(0xFF00FFCC),
        shadowColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 19, color: Color(0xFF00FFCC), fontFamily: 'Courier'),
        titleSmall: TextStyle(fontSize: 14, color: Color(0xFF00FFCC), fontFamily: 'Courier'),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xFFAAAAAA), fontFamily: 'Courier'),
        bodyMedium: TextStyle(fontSize: 14, color: Color(0xFFFFFFFF), fontFamily: 'Courier'),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00FFCC),
          foregroundColor: const Color(0xFF0B0E14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF00FFCC),
          side: const BorderSide(color: Color(0xFF00FFCC)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF00FFCC),
        ),
      ),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00FFCC),
        secondary: Color(0xFF00E5B8),
        background: Color(0xFF0B0E14),
      ),
    ).copyWith(
      extensions: <ThemeExtension<dynamic>>[
        cyberProxyColors,
        TabbarTheme.dark,
      ],
    );
  }

  static ThemeData get nordicFrost {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFFAFBFC),
      dialogBackgroundColor: const Color(0xFFFFFFFF),
      cardColor: const Color(0xFFECEFF4),
      hoverColor: const Color(0xFFE5E9F0),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFAFBFC),
        foregroundColor: Color(0xFF2E3440),
        shadowColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 19, color: Color(0xFF2E3440)),
        titleSmall: TextStyle(fontSize: 14, color: Color(0xFF3B4252)),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xFF4C566A)),
        bodyMedium: TextStyle(fontSize: 14, color: Color(0xFF2E3440)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF5E81AC),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF5E81AC),
          side: const BorderSide(color: Color(0xFF5E81AC)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFF5E81AC),
        secondary: Color(0xFF81A1C1),
        background: Color(0xFFFAFBFC),
      ),
    ).copyWith(
      extensions: <ThemeExtension<dynamic>>[
        nordicFrostColors,
        TabbarTheme.light,
      ],
    );
  }

  static ThemeData get legacyConsole {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: Colors.black,
      dialogBackgroundColor: const Color(0xFF050505),
      cardColor: const Color(0xFF0A0A0A),
      hoverColor: const Color(0xFF003300),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Color(0xFF00FF00),
        shadowColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 19, color: Color(0xFF00FF00), fontFamily: 'Courier'),
        titleSmall: TextStyle(fontSize: 14, color: Color(0xFF00DD00), fontFamily: 'Courier'),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xFF00AA00), fontFamily: 'Courier'),
        bodyMedium: TextStyle(fontSize: 14, color: Color(0xFF00FF00), fontFamily: 'Courier'),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFF00FF00),
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFF00FF00),
          side: const BorderSide(color: Color(0xFF00FF00)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(0)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFF00FF00),
        ),
      ),
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFF00FF00),
        secondary: Color(0xFF00AA00),
        background: Colors.black,
      ),
    ).copyWith(
      extensions: <ThemeExtension<dynamic>>[
        legacyConsoleColors,
        TabbarTheme.dark,
      ],
    );
  }

  static ThemeData get obsidianNight {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF050505),
      dialogBackgroundColor: const Color(0xFF111111),
      unselectedWidgetColor: Colors.teal[700],
      canvasColor: const Color(0xFF0B0E14),
      cardColor: const Color(0xFF111111),
      hoverColor: const Color(0xFF222222),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF050505),
        foregroundColor: Colors.white,
        shadowColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 19, color: Colors.white),
        titleSmall: TextStyle(fontSize: 14, color: Colors.white70),
        bodySmall: TextStyle(fontSize: 12, color: Colors.white60),
        bodyMedium: TextStyle(fontSize: 14, color: Colors.white),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.white,
          side: const BorderSide(color: Colors.white),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: Colors.white,
        ),
      ),
      colorScheme: const ColorScheme.dark(
        primary: Colors.white,
        secondary: Colors.white70,
        background: Color(0xFF050505),
      ),
    ).copyWith(
      extensions: <ThemeExtension<dynamic>>[
        obsidianNightColors,
        TabbarTheme.dark,
      ],
    );
  }
  static ThemeData get sakuraBloom {
    return ThemeData(
      useMaterial3: false,
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFFFF5F8),
      dialogBackgroundColor: const Color(0xFFFFFFFF),
      cardColor: const Color(0xFFFCE4EC),
      hoverColor: const Color(0xFFFFF0F5),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFFF5F8),
        foregroundColor: Color(0xFF880E4F),
        shadowColor: Colors.transparent,
      ),
      textTheme: const TextTheme(
        titleLarge: TextStyle(fontSize: 19, color: Color(0xFF880E4F)),
        titleSmall: TextStyle(fontSize: 14, color: Color(0xFFAD1457)),
        bodySmall: TextStyle(fontSize: 12, color: Color(0xFFC2185B)),
        bodyMedium: TextStyle(fontSize: 14, color: Color(0xFF880E4F)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFE91E8C),
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: const Color(0xFFE91E8C),
          side: const BorderSide(color: Color(0xFFE91E8C)),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: const Color(0xFFE91E8C),
        ),
      ),
      colorScheme: const ColorScheme.light(
        primary: Color(0xFFE91E8C),
        secondary: Color(0xFFF48FB1),
        background: Color(0xFFFFF5F8),
      ),
    ).copyWith(
      extensions: <ThemeExtension<dynamic>>[
        sakuraBloomColors,
        TabbarTheme.light,
      ],
    );
  }
}
