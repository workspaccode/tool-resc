# ML Kit text recognition: the plugin references the Chinese, Devanagari,
# Japanese and Korean recognizers, but only the Latin one is bundled. Tell R8
# those optional classes are intentionally absent.
-dontwarn com.google.mlkit.vision.text.chinese.**
-dontwarn com.google.mlkit.vision.text.devanagari.**
-dontwarn com.google.mlkit.vision.text.japanese.**
-dontwarn com.google.mlkit.vision.text.korean.**
