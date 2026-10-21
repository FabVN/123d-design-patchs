==============================================================================
 123D Design - FrenchLanguage
------------------------------------------------------------------------------
 Debloque la langue francaise (fr-FR) et l'active dans 123D Design.
==============================================================================

POURQUOI LE FRANCAIS ETAIT IGNORE
---------------------------------
Le build contient deja toute la traduction francaise :
    C:\Program Files\Autodesk\123D Design\StringTable\fr-FR\*.xml

MAIS NsBase10.dll contient une whitelist codée en dur dans
BootstrapOptionGroup::isLanguageSupported() :
    en-US, es-ES, ja-JP, zh-CN, tr-TR        (fr-FR absent)

Au demarrage, BootstrapOptionGroup::userLanguage() verifie la valeur
persistee : si elle n'est pas whitelistee, l'option est REECRITE a en-US.
C'est pourquoi toute injection de fr-FR dans le XML etait annulee au
lancement suivant (Options.Get affichait en-US, dirty=1).

Le build Autodesk ne livre pas les fichiers fr-FR .qm. Le package fournit
qml_fr.qm et qt_fr.qm pour les charger sous la langue fr-FR.

QUE FAIT LE PATCH
-----------------
1) Binaire (NsBase10.dll, offset fichier 0x518D0 / VA 0x1800524D0) :
      avant : 40 53 48 83 EC 30     push rbx ; sub rsp,30h   (prologue)
      apres : B8 01 00 00 00 C3     mov eax,1 ; ret          (toujours vrai)
   => isLanguageSupported() retourne toujours TRUE.
   Effet de bord : toute langue acceptee comme "supportee" ; si un code
   sans StringTable est force, l'UI retombe en anglais (comportement
   de secours standard de StringTable). Pas de risque.

2) Chargeur des traductions (NuBase10.dll) :
   redirige les entrees es-ES vers qml_fr.qm / qt_fr.qm et neutralise
   le controle de hash Autodesk, car les fichiers fr du package ne sont
   pas signes Autodesk. La langue es-ES conserve ses StringTable XML,
   mais ne charge plus ses anciens fichiers .qm.

3) Traductions Qt/QML :
   installe qm\qml_fr.qm et qm\qt_fr.qm dans
   StringTable\qtTranslations\. Les fichiers precedents sont sauvegardes
   en .orig avant remplacement, puis restaures par le script de retrait.

4) Option (UTF-16 preserve, idempotent) :
      %APPDATA%\Autodesk\123D Design\Options\NMachineSpecificOptions.xml
      <BootstrapOptionsGroup> : <userLanguageOptionId Value="fr-FR"/>

5) Tooltip des boutons de flyout (qrc_Resources.rcc) :
   SecondaryToolbarButton.qml calculait la largeur sur toolHelptext, souvent
   vide. Le patch utilise tooltext.paintedWidth et reduit la hauteur fixe de
   38 a 24*scaleFactor. Le RCC est verifie avant et apres modification :
   zlib, checksum Adler-32, taille QML et en-tete de la ressource suivante.
   Le slot zlib est limite a 888 octets; aucun octet de la ressource voisine
   n'est ecrit. Les deux fichiers .qm requis et le RCC sont prevalides avant
   la premiere ecriture dans l'installation.

RESULTAT
--------
Au lancement suivant, l'interface charge StringTable\fr-FR\*.xml ainsi que
les traductions QML/Qt du package. Les tooltips des commandes de flyout
mesurent le libelle principal et ont une hauteur reduite.
Preferences > langue affiche "French" dans la liste (languageExists trouve
StringTable\fr-FR\NsBase10.xml).

UTILISATION
-----------
  Install-FrenchLanguage.cmd   applique le patch (elevation admin requise)
  Remove-FrenchLanguage.cmd    restaure les fichiers .orig et retire les
                               traductions ajoutees par le package

  Options du script :
    powershell -File Apply-FrenchLanguage.ps1 -Restore
    powershell -File Apply-FrenchLanguage.ps1 -SkipOptionWrite
        (patche la DLL sans imposer fr-FR : permet de choisir une autre
         langue via Options.Language ou les Preferences)
    powershell -File Apply-FrenchLanguage.ps1 -PreflightOnly
        (verifie tous les pre-requis sans ecrire dans l'installation)
    powershell -File Apply-FrenchLanguage.ps1 -InstallDir "D:\123D Design"
        (chemin d'installation non standard - defaut :
         C:\Program Files\Autodesk\123D Design)

SECURITE
--------
- Fermer 123D Design avant application ou restauration (DLL/RCC verrouilles
  et options reecrites a la fermeture de l'application).
- Le patch refuse les octets inattendus dans les DLL et les metadonnees,
  tailles ou contenus RCC non reconnus.
- Les .orig sont crees avant remplacement et ne sont jamais re-ecrases.
- Le retrait restaure les fichiers preexistants, y compris les .qm, s'ils
  etaient deja presents avant l'installation.
- L'option de langue est ecrite dans %APPDATA% de la session qui execute
  le script. Si l'elevation UAC s'ouvre sous un COMPTE ADMINISTRATEUR
  DIFFERENT de celui qui lance 123D, l'option ira dans le mauvais profil :
  lancez le .cmd depuis le compte utilisateur de 123D (UAC garde le meme
  profil), ou choisissez "French" dans Preferences apres l'installation.

VERIFIE SUR
-----------
  NsBase10.dll  SHA256 8c04ce615f811c3327c26060830b1b2f3522f901c4779798940a9b73cbcfb567
  (123D Design R2.2 - build distribue par Autodesk avant l'arret du service)
==============================================================================
