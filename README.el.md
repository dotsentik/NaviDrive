# NaviDrive

<p align="center"><img src="docs/screenshots/navidrive-hero.png" alt="NaviDrive: πρόγραμμα-πελάτης Google Drive και Dropbox για macOS" width="880"></p>

<p align="center">Εγγενές πρόγραμμα-πελάτης Google Drive και Dropbox για macOS, εστιασμένο σε γρήγορες λήψεις και μεταφορτώσεις μεγάλων αρχείων και φακέλων με δυνατότητα συνέχισης.</p>

Εγγενές πρόγραμμα-πελάτης Google Drive και Dropbox για macOS, εστιασμένο σε γρήγορες λήψεις και μεταφορτώσεις μεγάλων αρχείων και φακέλων με δυνατότητα συνέχισης.

[English version](README.md)

## Δυνατότητες

- Περιήγηση στο Google Drive («Το Drive μου», «Κοινόχρηστα με εμένα») και στο Dropbox· πολλά cloud συνδεδεμένα ταυτόχρονα.
- Διαχείριση λήψεων: παράλληλες λήψεις σε τμήματα με προσαρμοστικό αριθμό ταυτόχρονων συνδέσεων, παύση και συνέχιση, πρόοδος που διατηρείται μετά από επανεκκινήσεις, διακοπές δικτύου και αποσύνδεση δίσκων.
- Έλεγχος αθροίσματος ελέγχου μετά τη λήψη (MD5 για το Google Drive, content hash για το Dropbox).
- Λήψη σε προεπιλεγμένο φάκελο, σε φάκελο της επιλογής σας ή σε εξωτερικό δίσκο· μόνιμες τοποθεσίες αποθήκευσης ανά φάκελο cloud· έλεγχος ελεύθερου χώρου πριν από τη λήψη.
- Δείχνει ποια αρχεία του cloud έχουν ήδη ληφθεί σε αυτό το Mac.
- Διαχείριση μεταφορτώσεων με δυνατότητα συνέχισης· «Upload to NaviDrive» στο μενού Υπηρεσίες του Finder.
- Προσθήκη αρχείων και φακέλων μέσω συνδέσμου (σύνδεσμος ή ID του Google Drive, κοινόχρηστος σύνδεσμος του Dropbox).
- Υπολογισμός μεγέθους φακέλων, νέος φάκελος, μετακίνηση, μετακίνηση στον Κάδο.
- Παρακολουθεί τα ημερήσια όρια μεταφοράς του Google Drive και συνεχίζει αυτόματα τις μεταφορές όταν αυτά μηδενίζονται.
- Κατάσταση στη γραμμή μενού, προαιρετικά «διατήρηση του Mac σε εγρήγορση κατά τις μεταφορές», «Τερματισμός όταν ολοκληρωθεί», κράτημα του ⌘Q για τερματισμό.
- Ενημερώσεις μέσα από την εφαρμογή από τα GitHub Releases: εβδομαδιαίος ή χειροκίνητος έλεγχος· η λήψη επαληθεύεται (SHA-256, πιστοποιητικό υπογραφής, έκδοση) πριν από την εγκατάσταση.
- Περιβάλλον εργασίας στα αγγλικά και στα ρωσικά.

## Απαιτήσεις

- macOS 15 ή νεότερο.
- Apple silicon ή Intel: τα DMG των εκδόσεων που δημιουργούνται με το `Scripts/release.sh` είναι universal (`arm64` + `x86_64`)· μια απλή τοπική δημιουργία είναι μόνο `arm64`.
- Για δημιουργία: Xcode 16 ή νεότερο και [XcodeGen](https://github.com/yonaskolb/XcodeGen).

## Εγκατάσταση

Κατεβάστε το `NaviDrive-X.Y.Z.dmg` από τα [GitHub Releases](https://github.com/dotsentik/NaviDrive/releases), ανοίξτε το και σύρετε το NaviDrive στις Εφαρμογές. Πριν το ανοίξετε για πρώτη φορά, διαβάστε την ενότητα [Πρώτη εκκίνηση](#πρώτη-εκκίνηση).

## Πρώτη εκκίνηση

Οι εκδόσεις είναι υπογεγραμμένες με το δικό πιστοποιητικό του έργου και δεν έχουν επικυρωθεί (notarized) από την Apple, γι' αυτό σε άλλο Mac το Gatekeeper μπλοκάρει την πρώτη εκκίνηση από το DMG.

1. Σύρετε το NaviDrive στις Εφαρμογές και έπειτα κάντε δεξί κλικ πάνω του → Άνοιγμα → Άνοιγμα.
2. Αν αυτό δεν βοηθήσει, εκτελέστε στο Τερματικό:
   `xattr -dr com.apple.quarantine /Applications/NaviDrive.app`
3. Αν το DMG ήρθε μέσω εφαρμογής ανταλλαγής μηνυμάτων με sandbox (για παράδειγμα, Telegram) και το macOS εμφανίζει «File created by an AppSandbox», εκτελέστε:
   `sudo xattr -cr /Applications/NaviDrive.app`

Για να αποφύγετε το βήμα 3, κατεβάστε το DMG από τα GitHub Releases με πρόγραμμα περιήγησης ή στείλτε το μέσω AirDrop.

Αυτά τα βήματα χρειάζονται μόνο μία φορά. Οι ενημερώσεις που εγκαθίστανται μέσα από την εφαρμογή (NaviDrive → Check for Updates…) δεν τα χρειάζονται.

## Δημιουργία από τον πηγαίο κώδικα

```sh
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill in the values, see below
xcodegen generate
xcodebuild -project NaviDrive.xcodeproj -scheme NaviDrive -configuration Release \
  -derivedDataPath ./DerivedData -quiet build
Scripts/make_dmg.sh   # ~/Desktop/NaviDrive-<version>.dmg
```

Οι εκδόσεις δημιουργούνται με το `Scripts/release.sh X.Y.Z` από καθαρό κλάδο `main`: το σενάριο δημιουργεί universal εφαρμογή, ελέγχει το πιστοποιητικό υπογραφής έναντι του `Config/signing-fingerprint.txt`, δημιουργεί τα `NaviDrive-X.Y.Z.dmg` και `NaviDrive-X.Y.Z.dmg.sha256`, παίρνει τις σημειώσεις έκδοσης από το `CHANGELOG.md` και τις δημοσιεύει με το `gh`. Το `Scripts/release.sh --dry-run X.Y.Z` δημιουργεί και ελέγχει τα αρχεία χωρίς να τα δημοσιεύσει.

Το `NaviDrive.xcodeproj` παράγεται από το `project.yml`· αλλάξτε τις ρυθμίσεις δημιουργίας εκεί και όχι στο έργο του Xcode.

Οι εκδόσεις υπογράφονται με το πιστοποιητικό «NaviDrive Signing». Αν δεν υπάρχει στην Κλειδοθήκη σας, αλλάξτε το `CODE_SIGN_IDENTITY` στο `project.yml` για τοπική δημιουργία. Αντίγραφα υπογεγραμμένα με άλλο πιστοποιητικό δεν μπορούν να ενημερώσουν αντίγραφα υπογεγραμμένα με το αρχικό· δείτε το [docs/SIGNING.md](docs/SIGNING.md).

## Ρύθμιση OAuth

Τα διαπιστευτήρια των cloud δεν αποθηκεύονται στο αποθετήριο. Το `Config/NaviDrive.xcconfig` περιλαμβάνει το μη παρακολουθούμενο `Config/Secrets.xcconfig`· οι τιμές του φτάνουν στο `Info.plist` ως `$(GOOGLE_CLIENT_ID)`, `$(GOOGLE_CLIENT_SECRET)` και `$(DROPBOX_APP_KEY)`.

- **Google Drive**: δημιουργήστε στο Google Cloud Console έναν πελάτη OAuth τύπου «Desktop app» με ενεργοποιημένο το Drive API και βάλτε το Client ID και το Client Secret του στο `Config/Secrets.xcconfig`. Χωρίς αυτά η εφαρμογή δεν έχει ενσωματωμένη σύνδεση στο Google και οι χρήστες εισάγουν το δικό τους Client ID και Client Secret στις Ρυθμίσεις (αποθηκεύονται στην Κλειδοθήκη).
- **Dropbox**: δημιουργήστε μια εφαρμογή στο dropbox.com/developers/apps, προσθέστε το redirect URI `http://127.0.0.1:53682/callback` και βάλτε το App key της στο `DROPBOX_APP_KEY`. Χωρίς αυτό η σύνδεση στο Dropbox δεν είναι διαθέσιμη.

## Ασφάλεια και ιδιωτικότητα

- Τα διακριτικά OAuth και τα διαπιστευτήρια που εισάγει ο χρήστης αποθηκεύονται στην Κλειδοθήκη του macOS.
- Η εφαρμογή επικοινωνεί μόνο με το Google (accounts.google.com, oauth2.googleapis.com, www.googleapis.com) και το Dropbox (dropbox.com, api.dropboxapi.com, content.dropboxapi.com), καθώς και με το GitHub (api.github.com και τους διακομιστές λήψης εκδόσεων) κατά τον έλεγχο για ενημερώσεις. Δεν υπάρχουν αναλυτικά στοιχεία ούτε τηλεμετρία.
- Η σύνδεση χρησιμοποιεί έναν τοπικό διακομιστή loopback στο 127.0.0.1 για να λάβει την απάντηση OAuth.
- Η ουρά, το ιστορικό και τα μεγέθη φακέλων αποθηκεύονται σε τοπική βάση δεδομένων SQLite στο `~/Library/Application Support/NaviDrive`.

## Δομή αποθετηρίου

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

## Άδεια χρήσης

MIT, δείτε το αρχείο [LICENSE](LICENSE).

<sub>Η μετάφραση έγινε με τη βοήθεια ΤΝ — διορθώσεις είναι ευπρόσδεκτες στα [issues](https://github.com/dotsentik/NaviDrive/issues).</sub>
