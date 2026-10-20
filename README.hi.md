# NaviDrive

<p align="center"><img src="docs/screenshots/navidrive-hero.png" alt="NaviDrive: macOS के लिए Google Drive और Dropbox क्लाइंट" width="880"></p>

<p align="center">macOS के लिए Google Drive और Dropbox का नेटिव क्लाइंट, जो बड़ी फ़ाइलों और फ़ोल्डरों को तेज़ी से डाउनलोड और अपलोड करने पर केंद्रित है, और रुकने के बाद वहीं से फिर शुरू कर सकता है।</p>

macOS के लिए Google Drive और Dropbox का नेटिव क्लाइंट, जो बड़ी फ़ाइलों और फ़ोल्डरों को तेज़ी से डाउनलोड और अपलोड करने पर केंद्रित है, और रुकने के बाद वहीं से फिर शुरू कर सकता है।

[English version](README.md)

## सुविधाएँ

- Google Drive (My Drive, Shared with me) और Dropbox ब्राउज़ करें; एक साथ कई क्लाउड जोड़े जा सकते हैं।
- डाउनलोड मैनेजर: अनुकूली समानांतरता के साथ हिस्सों में समानांतर डाउनलोड, रोकना और फिर शुरू करना; ऐप को दोबारा चालू करने, नेटवर्क टूटने और डिस्क हटने के बाद भी प्रगति सुरक्षित रहती है।
- डाउनलोड के बाद चेकसम की जाँच (Google Drive के लिए MD5, Dropbox के लिए content hash)।
- डिफ़ॉल्ट फ़ोल्डर, अपने चुने हुए फ़ोल्डर या बाहरी डिस्क में डाउनलोड; हर क्लाउड फ़ोल्डर के लिए स्थायी सेव लोकेशन; डाउनलोड से पहले खाली जगह की जाँच।
- दिखाता है कि क्लाउड की कौन-सी फ़ाइलें इस Mac पर पहले से डाउनलोड हो चुकी हैं।
- फिर से शुरू होने वाले अपलोड के साथ अपलोड मैनेजर; Finder के Services मेनू में "Upload to NaviDrive"।
- लिंक से फ़ाइलें और फ़ोल्डर जोड़ें (Google Drive लिंक या ID, Dropbox शेयर्ड लिंक)।
- फ़ोल्डर का आकार गिनना, नया फ़ोल्डर बनाना, स्थानांतरित करना, ट्रैश में ले जाना।
- Google Drive की दैनिक ट्रांसफ़र सीमाओं पर नज़र रखता है और सीमा रीसेट होते ही ट्रांसफ़र अपने-आप फिर शुरू करता है।
- मेनू बार में स्थिति, वैकल्पिक "ट्रांसफ़र के दौरान Mac को जगाए रखें", "काम पूरा होने पर बंद करें", बंद करने के लिए ⌘Q दबाए रखें।
- GitHub Releases से ऐप के अंदर अपडेट: साप्ताहिक या मैन्युअल जाँच; इंस्टॉल करने से पहले डाउनलोड की जाँच होती है (SHA-256, साइनिंग सर्टिफ़िकेट, वर्ज़न)।
- अंग्रेज़ी और रूसी इंटरफ़ेस।

## आवश्यकताएँ

- macOS 15 या नया।
- Apple silicon या Intel: `Scripts/release.sh` से बने रिलीज़ DMG यूनिवर्सल होते हैं (`arm64` + `x86_64`); सामान्य लोकल बिल्ड केवल `arm64` होता है।
- बिल्ड करने के लिए: Xcode 16 या नया और [XcodeGen](https://github.com/yonaskolb/XcodeGen)।

## इंस्टॉलेशन

[GitHub Releases](https://github.com/dotsentik/NaviDrive/releases) से `NaviDrive-X.Y.Z.dmg` डाउनलोड करें, उसे खोलें और NaviDrive को Applications में खींचें। पहली बार खोलने से पहले [पहली बार चलाना](#पहली-बार-चलाना) पढ़ें।

## पहली बार चलाना

रिलीज़ बिल्ड प्रोजेक्ट के अपने सर्टिफ़िकेट से साइन किए गए हैं और Apple द्वारा नोटराइज़ नहीं हैं, इसलिए किसी दूसरे Mac पर Gatekeeper DMG से पहली बार चलाने को रोक देता है।

1. NaviDrive को Applications में खींचें, फिर उस पर राइट-क्लिक करें → Open → Open।
2. अगर इससे काम न बने, तो Terminal में चलाएँ:
   `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`
3. अगर DMG सैंडबॉक्स वाले किसी मैसेंजर (जैसे Telegram) से आया है और macOS "File created by an AppSandbox" दिखाता है, तो चलाएँ:
   `sudo xattr -cr /Applications/NaviDrive.app`

चरण 3 से बचने के लिए DMG को ब्राउज़र में GitHub Releases से डाउनलोड करें या AirDrop से भेजें।

ये चरण सिर्फ़ एक बार ज़रूरी हैं। ऐप के अंदर से इंस्टॉल किए गए अपडेट (NaviDrive → Check for Updates…) के लिए इनकी ज़रूरत नहीं होती।

## सोर्स से बिल्ड करना

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill in the values, see below
xcodegen generate
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release \
  -derivedDataPath ./DerivedData -quiet build
Scripts/make_dmg.sh   # ~/Desktop/NaviDrive-<version>.dmg
```

रिलीज़ साफ़ `main` से `Scripts/release.sh X.Y.Z` चलाकर बनाए जाते हैं: स्क्रिप्ट यूनिवर्सल ऐप बिल्ड करती है, साइनिंग सर्टिफ़िकेट को `Config/signing-fingerprint.txt` से मिलाती है, `NaviDrive-X.Y.Z.dmg` और `NaviDrive-X.Y.Z.dmg.sha256` बनाती है, रिलीज़ नोट्स `CHANGELOG.md` से लेती है और उन्हें `gh` से प्रकाशित करती है। `Scripts/release.sh --dry-run X.Y.Z` फ़ाइलें बनाकर जाँचती है, पर प्रकाशित नहीं करती।

`NaviDrive.xcodeproj` को `project.yml` से जनरेट किया जाता है; बिल्ड सेटिंग्स वहीं बदलें, Xcode प्रोजेक्ट में नहीं।

रिलीज़ बिल्ड "NaviDrive Signing" सर्टिफ़िकेट से साइन किए जाते हैं। अगर यह आपके Keychain में नहीं है, तो लोकल बिल्ड के लिए `project.yml` में `CODE_SIGN_IDENTITY` बदलें। किसी दूसरे सर्टिफ़िकेट से साइन की गई कॉपी मूल सर्टिफ़िकेट से साइन की गई कॉपी को अपडेट नहीं कर सकती; देखें [docs/SIGNING.md](docs/SIGNING.md)।

## OAuth कॉन्फ़िगरेशन

क्लाउड क्रेडेंशियल रिपॉज़िटरी में नहीं रखे जाते। `Config/NaviDrive.xcconfig` में अनट्रैक्ड `Config/Secrets.xcconfig` शामिल है; इसकी वैल्यू `Info.plist` में `$(GOOGLE_CLIENT_ID)`, `$(GOOGLE_CLIENT_SECRET)` और `$(DROPBOX_APP_KEY)` के रूप में पहुँचती हैं।

- **Google Drive**: Google Cloud Console में Drive API चालू करके "Desktop app" प्रकार का OAuth क्लाइंट बनाएँ, और उसका Client ID और Client Secret `Config/Secrets.xcconfig` में डालें। इनके बिना बिल्ड में Google साइन-इन पहले से शामिल नहीं होता, और उपयोगकर्ता सेटिंग्स में अपना Client ID और Client Secret डालते हैं (ये Keychain में सहेजे जाते हैं)।
- **Dropbox**: dropbox.com/developers/apps पर एक ऐप बनाएँ, redirect URI `http://127.0.0.1:53682/callback` जोड़ें, और उसकी App key `DROPBOX_APP_KEY` में डालें। इसके बिना Dropbox साइन-इन उपलब्ध नहीं होता।

## सुरक्षा और गोपनीयता

- OAuth टोकन और उपयोगकर्ता द्वारा डाले गए क्रेडेंशियल macOS Keychain में सहेजे जाते हैं।
- ऐप केवल Google (accounts.google.com, oauth2.googleapis.com, www.googleapis.com) और Dropbox (dropbox.com, api.dropboxapi.com, content.dropboxapi.com) से, और अपडेट जाँचते समय GitHub (api.github.com और उसके रिलीज़ डाउनलोड होस्ट) से बात करता है। कोई एनालिटिक्स या टेलीमेट्री नहीं है।
- साइन-इन OAuth जवाब पाने के लिए 127.0.0.1 पर एक लोकल loopback सर्वर का उपयोग करता है।
- कतार, इतिहास और फ़ोल्डरों के आकार `~/Library/Application Support/NaviDrive` में एक लोकल SQLite डेटाबेस में रखे जाते हैं।

## रिपॉज़िटरी की संरचना

```
Sources/
  API/        Google Drive and Dropbox API clients and providers
  App/        app entry point, AppModel and its extensions
  Auth/       OAuth, loopback server, token management
  Cloud/      cloud-agnostic item and provider types
  Download/   download scheduler, workers, chunk writing, verification
  Upload/     upload planner, scheduler, workers
  Update/     update check, verification and installation
  Storage/    SQLite database, settings, Keychain
  Models/     shared models and formatters
  Views/      SwiftUI views
Resources/    asset catalog, localization (en, ru), design sources
Support/      Info.plist
Config/       xcconfig files, signing fingerprint
Scripts/      release, DMG and icon tooling
Tests/        unit tests (update logic)
docs/         signing and maintenance documentation
project.yml   XcodeGen project definition
```

## लाइसेंस

MIT, [LICENSE](LICENSE) फ़ाइल देखें।

<sub>यह अनुवाद AI की मदद से किया गया है — सुधार [issues](https://github.com/dotsentik/NaviDrive/issues) में स्वागत योग्य हैं।</sub>
