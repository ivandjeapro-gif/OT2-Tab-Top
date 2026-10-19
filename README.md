# ORE TRACKING — OT2 Tab (build)

Application Flutter de gestion des activites de minage (spotters, DT, excavatrices)
et serveur central Google Apps Script.

Ce depot contient **uniquement les elements necessaires au build**.

## Prerequis

- Flutter SDK >= 3.9
- Android SDK (pour l'APK)
- JDK 17

## Build

    flutter pub get
    flutter build apk --debug
    # ou
    flutter build apk --release

L'APK est produit dans `build/app/outputs/flutter-apk/`.

## Installation sur tablette

    adb install -r build/app/outputs/flutter-apk/app-debug.apk

## Serveur (Google Apps Script)

Le serveur est le fichier `server_OT` a la racine.

1. Creer un Google Spreadsheet (les onglets sont crees automatiquement).
2. Extensions > Apps Script > coller le contenu de `server_OT`.
3. Renseigner `CONFIG` : `SPREADSHEET_ID`, `TOKEN`, `DOSSIER_PLANS_ID`, `FICHIER_PISTES_ID`.
4. Executer une fois `initialiserOnglets()` puis `amorcerDepuisDrive()`.
5. Deployer en Web App : Execute as **Me**, Who has access **Anyone**.
6. Sur la tablette : Parametres > `api_base` = URL `/exec`, `api_token` = `CONFIG.TOKEN`.

## Structure

    lib/
      data/          base locale SQLite, transmetteur HTTP, synchronisation
      models/        Blast, BlocTravail, LigneBlast, Profil, TypeDT...
      screens/       splash, login, spotter, dt, excavator, parametres
      state/         Session (etat partage)
      communication/ BLE, Wi-Fi, GPS, alertes
      theme/         palette et mise en page responsive
      widgets/       shell commun, bandeaux, badges
    android/         projet Android (build APK)
    windows/         cible Windows
    web/             cible web
    assets/          logos, plans, sons
    server_OT        serveur Apps Script (deploiement manuel)

## Modele de donnees metier

- **Blast** = numero de **pattern** (113, 107, 106)
- **RL** = numero de **flitch** (260, 262.5, 232.5)
- **Bloc** = paire (numero, carte) : le meme numero peut exister sur plusieurs RL

Nomenclature des cartes :
`flitch_activite_site_profDebut_profFin_pattern[_nbBlocs]`