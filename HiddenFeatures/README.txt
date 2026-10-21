================================================================================
 123D Design - HiddenFeatures
 Activation d'options internes cachees + documentation des flags de lancement
================================================================================

Decouvert par analyse REA (Ghidra) de :
  - C:\Program Files\Autodesk\123D Design\123D Design.exe
      SHA256 57148e59bdc75d8eb763982ee7e8eba87c3fc8bd37090906b4b8cfd550a37a40
  - C:\Program Files\Autodesk\123D Design\NuBase10.dll
      SHA256 16bc1320024cabcba4526d9970d147a5307309f78f8efcab9b51af8e55cd720f
  - NsBase10.dll, Na123DUI10.dll, NuCommands10.dll (strings/symboles)

Chaque point ci-dessous a ete VERIFIE au runtime sur le build installe
(sauf mention "statique seulement"). Verification via :
  "123D Design.exe" --execute "Options.List -output <fichier>"


--------------------------------------------------------------------------------
 1. CE QUE FAIT LE PATCH (Install-HiddenFeatures.cmd)
--------------------------------------------------------------------------------
Ecrit des options dans les fichiers XML utilisateur - aucun binaire modifie :

%APPDATA%\Autodesk\123D Design\Options\NMachineSpecificOptions.xml
  <BootstrapOptionsGroup>  (options lues au demarrage, verifiees au runtime)
    Analytics        = 0   -> coupe la collecte d'evenements telemetry
    UpdateCheck      = 0   -> plus de requete de mise a jour (serveurs morts)
    FirstLaunch      = 0   -> saute le flux "premier lancement"
  NB : AnalyticsAlert est volontairement laisse a 1 (= "alerte privacy deja
       acquittee"). Verifie au runtime : la remettre a 0 fait reapparaitre
       le dialogue modal "Analytics" a chaque lancement.

%APPDATA%\Autodesk\123D Design\Autodesk\123D Design\Options\NGlobalOptions.xml
  <UIBaseOptionGroup ToolTip="Preferences controlling general UI behavior"
                     UserName="General">
    WantToShowTextCommands      = 1  -> affiche la FENETRE DE COMMANDES TEXTE
    TrackGoogleAnalytics        = 0  -> coupe la couche Google Analytics
    ShowWelcomeScreenOnStartup  = 0  -> demarrage direct (plus d'ecran d'accueil)

Backup : <fichier>.orig cree a cote de chaque XML au premier apply.
Rollback : Remove-HiddenFeatures.cmd restaure les .orig.
Fermer 123D Design avant application ou restauration : l'application peut
reecrire ses options a la fermeture de la session en cours.

Variantes du script :
  Apply-HiddenFeatures.ps1 -SkipTextCommands     (garde la fenetre texte OFF)
  Apply-HiddenFeatures.ps1 -KeepTelemetry        (garde Analytics/UpdateCheck)
  Apply-HiddenFeatures.ps1 -KeepWelcomeScreen    (garde l'ecran d'accueil)
  Apply-HiddenFeatures.ps1 -DebugEnvironment     (ajoute ShowDebugEnvironment=1)
  Apply-HiddenFeatures.ps1 -Restore              (equivaut a Remove-...)


--------------------------------------------------------------------------------
 2. LA FENETRE DE COMMANDES TEXTE (option phare)
--------------------------------------------------------------------------------
WantToShowTextCommands=1 affiche une console interne style DOS dans l'UI.
Elle accepte des commandes "SubjectArea.Operation" avec :
  ?                  -> aide + liste des Subject Areas
  ??                 -> inclut les 44 subject areas caches
  <Commande> /?      -> aide d'une commande
  <TAB>              -> auto-completion
  <commande> -output <fichier>  -> redirige la sortie vers un fichier

Subject Areas documentes (runtime) :
  Application Asset Associative AutoSave Clocks Commands CompanionApp
  Component Debug Diagnostics Document EntityTracking Expressions Fusion
  Geometry GlobalCoordinateAxes GraphicsMemory Instance Joints
  LocalToWorld Manipulator Materials Matrix MetaTypes Metrics MSketch
  NamedView Options PAsset PEntity PInstance POccurrence PSelections
  Python Selections Sketch StrongRef SynHub Translator TranslatorOptions
  UI Units UnitSystems Validation ViewCube ViewFragment WorldToLocal
  (+ 44 areas "caches" visibles via ??)

Exemples :
  Options.List /nondefault       -> options modifiees
  Options.Get <id>               -> valeur d'une option
  Options.Set <id> <valeur>      -> change une option (persiste a la fermeture)
  Options.Files                  -> liste les fichiers d'options
  ListDefinitions /AsXML         -> exporte TOUTES les definitions de commandes
  Commands.Start <id>            -> lance une commande par son id
  Options.Theme /Dark|/Light     -> theme sombre/clair
  Options.Language fr-FR         -> interface en francais (13 langues)
  Options.DeviceType /SW         -> rendu logiciel
  Options.driver /DX11|/DX9      -> pilote graphique (session suivante)
  Options.OpenMultipleFiles /on  -> ouvrir plusieurs fichiers dans l'UI
  Options.ShowAllCommands /on    -> afficher toutes les commandes
  Options.DebugEnvironment /Show -> environnement de debug
  Diagnostics.RunTests|RunPerfTests|RunGraphicsTests
  Transcripting.Replay <fichier> -> rejoue un transcript .txt/.py (interne)

Attention : certaines commandes sont INTERNES (ex. Commands.RunPython) et
refusees par --execute ("not external command") mais utilisables dans la
fenetre de commandes texte. Les commandes Crash / ShowCERDialog /
Diagnostics.RunTests existent aussi - a n'utiliser qu'en connaissance.


--------------------------------------------------------------------------------
 3. FLAGS DE LIGNE DE COMMANDE (dossier Launchers\)
--------------------------------------------------------------------------------
Documentes dans l'aide embarquee du lanceur (statique) :

  --execute "<TextCommand>"   execute une commande texte apres chargement
                              des add-ins            [VERIFIE]
  -input <fichier>            fichier de commandes (PipeIn)
  -output <fichier>           sortie des commandes (PipeOut)
  --nologo                    desactive le splash screen
  --swrenderer                force le rendu logiciel
  --exitAfterAddIn            quitte apres chargement des add-ins (headless)
  --enable "<addin>"          active un add-in au lancement
  --disable "<addin>"         desactive un add-in au lancement
  --log <fichier>             journalise la sortie console dans un fichier
  --fullTest                  tests de regression apres chargement de l'UI
  --perfTest                  tests de perf puis quitte
  --showInternal              affiche les actions internes dans --help
  --help                      aide des options
  --exit                      quitte avant chargement des add-ins
  print                       "Not implemented yet" (option morte)
  AutoCAD / Inventor          boutons "return to AutoCAD/Inventor" (residus
                              du framework Fusion, integration non verifiee)

Lanceurs fournis (Launchers\) :
  123D-ListOptions.cmd    dump Options.List -> %TEMP%\123D_options.txt
  123D-TextCommand.cmd    --execute "<commande passee en argument>"
  123D-SW-Renderer.cmd    --swrenderer
  123D-NoLogo.cmd         --nologo
  123D-Headless.cmd       --exitAfterAddIn

Note : un seul --execute par lancement (les occurrences multiples ne se
chainent pas). Le format PipeIn (-input fichier -output fichier) n'a pas
produit de resultat au runtime dans nos tests ; --execute fonctionne.


--------------------------------------------------------------------------------
 4. VARIABLES D'ENVIRONNEMENT (statique - strings du binaire)
--------------------------------------------------------------------------------
  BUILDSERVER_DISABLE_GA          desactive Google Analytics (build servers)
  NEUTRON_DISABLE_ATTACH_CONSOLE  desactive l'attachement console debug
  CLOUD_LOGIN_USER / CLOUD_LOGIN_PASSWORD   login cloud (obsolete - ne PAS
                                  utiliser, les serveurs sont morts)

  Exemple :
      set BUILDSERVER_DISABLE_GA=1
      "123D Design.exe" --nologo


--------------------------------------------------------------------------------
 5. PYTHON / SCRIPTING (statique + partiellement verifie)
--------------------------------------------------------------------------------
Le build embarque :
  - Python 3.3 complet : C:\Program Files\Autodesk\123D Design\Python
  - API : C:\Program Files\Autodesk\123D Design\NeutronPythonTypes.Py
        (classes Point2, Point3, EntityRef, etc.)
  - Ns::TextCommandMgr::executeCommand, PythonManager::runScriptFile,
    PythonAutorunScripts (auto-run au demarrage), PathInfo::scriptsDirectory
  - Commands.RunPython "code ou fichier.py" (commande INTERNE - utilisable
    dans la fenetre de commandes texte, refusee par --execute)
  - Subject area "Python" : Python.Background /on|/off, Python.Stats
  - Transcript record/replay (TranscriptMgr) : macros .txt/.py
  - QtScript / JavaScript bridge (QtScript_Ad_4.dll)

Scripts d'exemple Autodesk absents du build (ressources seules conservees
dans Server\Base\Python\Scripts\). Le dossier d'autorun exact des scripts
n'a pas ete determine (scriptsDirectory a tracer).


--------------------------------------------------------------------------------
 6. AUTRES OPTIONS INTERNES NOTABLES (catalogue complet = Options.List)
--------------------------------------------------------------------------------
  STLTessellation (0-4+)            qualite d'export STL (defaut 3)
  UITheme (0)                       theme (aussi Options.Theme)
  MenuTimeout                       delai menus
  BrowserGroupExpansionLimit=100    limite d'expansion du browser
  ShowAllCommandsOptionId           afficher toutes les commandes
  ShowDebugScript                   widget debug script (session seule)
  ShowDebugDialog/ShowValidationDialog   dialogues debug (session seule)
  MaterialUIWindowRect / MotionStudyUIWindowRect / DebugDialogPos
  Device Type (1) / Autodetect / Graphics driver=VirtualDeviceDx11
  MinFPS=14, FXAA, MSAA, Optimized Rendering, Level Of Detail,
  CachingRenderingResult, Ground Shadows/Reflections, Ambient Occlusion,
  Environment=SkyRoom, Visual Style, CameraProjection, NPR Effect,
  Pixel-scale Factor, Display Silhouette, Object Shadow Type/Fit
  MultiThread*/BinaryPersistence/persistGRx/OpenMultipleFiles (NsBase)
  Disable Offline Workflow=OFF  (a laisser OFF)
  Default workspace=Sculpt, UnitSystem=MmMKS, GridSize*, Snap*, Language

NOTE : les options "wantToShow*" (Debug Environment, Debug Dialog, Debug
Script, Design Feed, Command Palette...) sont des bascules de SESSION :
elles se règlent via Options.Set/Options.* ou la fenetre de commandes ;
la persistence XML n'est garantie que pour celles verifiees dans ce kit.


--------------------------------------------------------------------------------
 7. LIMITES / PRECAUTIONS
--------------------------------------------------------------------------------
- Analyse statique Ghidra/REA + sondes runtime ciblees. Tout ce qui est
  dans la section 1 et les Options.* citees est VERIFIE au runtime.
  Les commandes marquees "interne"/"statique seulement" ne le sont pas.
- Diagnostics.RunTests/RunPerfTests/RunGraphicsTests, Crash, CERTest,
  MetaTypes.DumpData, TestTextCommand.* : outils de test Autodesk -
  instables/inutiles en production, ne pas activer.
- Les boutons AutoCAD/Inventor sont probablement des residus de Fusion.
- N'activez PAS de fonctions de licensing/expiration (lclz*).
- Le kit ne touche PAS aux fichiers du programme (Program Files) : aucune
  verification de hash binaire n'est necessaire. Compatible CrashFix +
  BoostStackMemory + OfflineKit (modifie seulement les XML utilisateur).
- Les deux fichiers d'options doivent exister : sur un PC ou 123D n'a
  JAMAIS ete lance, demarrez-le une premiere fois pour les generer avant
  d'appliquer ce patch.
- Apres une reinstallation ou un reset d'options (Options.Reset), reappliquer.

================================================================================
