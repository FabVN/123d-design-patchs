# 123D Design Patchs

Kit de patchs autonomes pour **Autodesk 123D Design** (R2.2), abandonné par
Autodesk en 2017 : correctifs de crashs, mémoire, fonctionnalités cachées et
traduction française.

> **Aucun binaire Autodesk n'est distribué.** Les scripts ne contiennent que
> la logique de patch : ils lisent les fichiers de *votre* installation,
> vérifient les empreintes et appliquent des modifications octet par octet,
> avec sauvegarde `.orig` / `.bak123d` et restauration intégrale.

## Démarrage rapide

1. Fermez 123D Design.
2. Lancez **`Menu-123D-Patchs.cmd`** et choisissez le patch (chaque paquet
   s'auto-élève si besoin) — ou appelez les `Install-*.cmd` directement.

## Contenu

| Paquet | Rôle |
|---|---|
| `BoostStackMemory/` | Réserve de pile de `123D Design.exe` : ~9,5 Mo → 256 Mo. Corrige les *stack overflow* sur les opérations lourdes (booléens, undo). |
| `CrashFix/` | Crash Â« null activeCommand Â» dans `Na123DUI10.dll` + blocage Â« Ctrl coincÃ© Â» (mode sÃ©lection faces/arÃªtes aprÃ¨s Snap) dans `NuBase10.dll`. Gardes de pointeurs nuls, relance de la commande par dÃ©faut sur pile vidÃ©e, retour 0 au lieu de `bad_lexical_cast`, patch de pile du lanceur. |
| `FrenchLanguage/` | Débloque et active **fr-FR** : whitelist de `NsBase10.dll`, redirection du chargeur `.qm` de `NuBase10.dll`, fichiers `qml_fr.qm`/`qt_fr.qm`, option XML, correctif des tooltips de flyout. |
| `HiddenFeatures/` | Options internes (XML utilisateur uniquement) : télémétrie / mises à jour / écran d'accueil **OFF**, fenêtre de commandes texte **ON**. + lanceurs documentés (`--execute`, `--swrenderer`, …). |

## Sécurité

- Hash SHA-256 vérifiés avant chaque écriture ; toute variante inconnue est
  **refusée** (jamais de patch à l'aveugle).
- Sauvegardes `.orig` / `.bak123d` créées une fois, jamais réécrasées.
- Chaque paquet a son `Remove-*.cmd` de retour arrière.
- Application ou restauration refusée si 123D Design est en cours d'exécution.
- `Apply-FrenchLanguage.ps1 -PreflightOnly` : contrôle complet sans écriture.

## Prérequis

- Windows 64 bits, 123D Design R2.2 installé.
- PowerShell ≥ 4.0 (`BoostStackMemory`, `CrashFix`), ≥ 5.1 (`FrenchLanguage`,
  `HiddenFeatures`).
- Les fichiers d'options de `%APPDATA%` doivent exister pour certains patchs :
  lancez 123D une première fois sur un PC neuf.

## Projet lié

[123d-offline-kit](https://github.com/FabVN/123d-offline-kit) — serveur local
et restauration des contenus en ligne (pièces, projets) après l'arrêt des
services Autodesk.

## Licence

MIT — voir [LICENSE](LICENSE). Les traductions `qm/*.qm` sont des fichiers
générés par ce projet (structure Qt), pas des binaires Autodesk.
