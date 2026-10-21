================================================================
123D Design - Correctif crash "null activeCommand" (v4)
================================================================

PROBLEME CORRIGE
----------------
Apres l'execution d'une commande Snap (ou la fin de toute
commande), le gestionnaire de commandes retourne
activeCommand() == NULL. Plusieurs sites de Na123DUI10.dll
appellent alors des methodes sur ce pointeur nul :

  * 5 predicats "isSelectCommand" (menus, ruban, Nudge)
  * le constructeur de menu FUN_1800AA120 (site 0xAAE46)
  * des chaines d'appels cmd->getter->getter... (6 slots)

Resultat d'origine : exception 0xC0000005, lecture a
l'adresse 0x18 (NuBase10.dll + 0x61BD0, getter fusionne
"mov rax,[rcx+0x18]; ret") -> fermeture de l'application.

SCENARIO TYPIQUE : faire un Snap, puis deplacer la vue,
ou ouvrir un menu du haut -> crash systematique.

NOUVEAU CAS CAPTURE (2026-10-21)
--------------------------------
Le dump 123D_minidump_20261021_002223.dmp montre une lecture a 0x18
depuis un pointeur nul dans NuBase10.dll+0x61BD0. Le retour appelant est
Na123DUI10.dll+0xCD6F2, juste apres un appel SelectToolbar a
CommandBase::commandDefinition avec R13=0. Les gardes v3 ne couvraient pas
ces appels directs; le v4 les redirige vers les chemins de repli existants.

CORRECTIF APPLIQUE
------------------
Un cave de code dans une nouvelle section PE ".fix" :

  1. caveA  : chaine activeCommand->commandDefinition avec
     tests de null (5 sleds de predicats redirigents dessus,
     chaque echec saute vers le chemin "faux" original)
  2. caveB  : garde "test r13,r13" pour le site du menu
     builder (saute le bloc si pas de commande active)
  3. stubs  : 6 wrappers "jrcxz -> retourne 0 ; jmp [slot]"
     appliques aux 657 sites d'appel reels (valides par
     desassemblage Ghidra, 0 faux positif)
  4. SelectToolbar : garde 3 appels directs a
     CommandBase::commandDefinition (RVA 0xCD313, 0xCD6EC, 0xCD89B).
     Si R13 (activeCommand) est nul, chaque chemin saute vers son
     fall-through/nettoyage existant au lieu d'appeler le getter.

La DLL originale est conservee dans Na123DUI10.dll.bak123d.
Si CrashFix modifie aussi le lanceur, il cree un backup distinct
123D Design.exe.bak123d-stack.

COMPATIBILITE
-------------
Uniquement la build exacte de Na123DUI10.dll :
  SHA256 original : 7D300E8DDBCCB5802EB59C3DA98DA162
                    4BD63155CB12A0F0F161B1544EB35A69
  SHA256 patche v3: 8C0774552555A2EFD2B3A47ADBF39E4B
                    E27F9BC13513F8A376512F2C232FE04E
  SHA256 patche v4: DD1B31295122B5DF99FF21A391BDACBB
                    3085A7BD5D10407753F40A8CF96346EC
Le script VERIFIE le hash et refuse de patcher une autre
version (securite : jamais de patch a l'aveugle).
Le v4 sait mettre a niveau le v3. Il refuse de remplacer toute
variante personnalisee non reconnue.

La DLL actuellement installee sur cette machine a le hash
9DF6EFBDE0A3E2622BC07D692352FFF7C61EA8487AEF5F52E6A1AC3C3F6183AE :
elle contient en plus des modifications d'etat premium, absentes du patch
standard. L'installateur v4 refuse de l'ecraser automatiquement.

Le patch optionnel du lanceur (reserve de pile 9,5 Mo -> 256 Mo)
est applique seulement si le champ PE vaut sa valeur d'origine.
Le chemin est derive de -InstallDir et le backup propre a CrashFix est
123D Design.exe.bak123d-stack. -Restore le restaure. Si la reserve etait
deja patchee par BoostStackMemory, CrashFix ne la revendique pas; utilisez
alors Remove-BoostStackMemory.cmd pour annuler ce patch-la.

INSTALLATION
------------
  Install-123DFix.cmd   (demande les droits admin automatiquement)

  ou manuellement, en PowerShell admin :
    .\Apply-123DFix.ps1
    .\Apply-123DFix.ps1 -InstallDir "D:\Autodesk\123D Design\Applications\123D"

DESINSTALLATION
---------------
  Remove-123DFix.cmd    (restaure le DLL et, s'il appartient a CrashFix,
                         le backup stack .bak123d-stack)

  ou : .\Apply-123DFix.ps1 -Restore
  Les anciennes installations ayant seulement 123D Design.exe.orig ont un
  backup partage ambigu; le rollback le laisse intact pour ne pas annuler
  un patch BoostStackMemory independant.

GENERER LA DLL SANS INSTALLER
-----------------------------
  .\Apply-123DFix.ps1 -OutputOnly C:\temp\Na123DUI10.dll
  -OutputOnly refuse la source et tout chemin dans le dossier d'installation
  123D. Choisir un dossier de sortie externe. Pour ne pas modifier le lanceur :
  -SkipExeStackFix.
  -InstallDir doit pointer vers le dossier Applications\123D; le chemin du
  lanceur est derive deux niveaux plus haut.

LIMITES CONNUES
---------------
  * Fermer 123D Design avant installation ou restauration. Le script
    refuse de modifier les fichiers si le processus est actif.
  * Les backups dont le hash ou les champs PE ne sont pas conformes sont
    refuses (pas de restauration avec un backup suspect).
  * Le correctif empeche le CRASH. Dans l'etat "aucune commande
    active", certaines evaluations d'UI repondent "vide" au lieu
    de planter ; un geste dependant de la commande terminee peut
    etre ignore (comportement degrade vs crash - choix delibere).
  * D'autres sites null dereference non encore observes peuvent
    exister ; signaler tout nouveau crash avec l'adresse du
    module fautif (Event Viewer / procdump).
  * Le patch ne modifie pas NuBase10.dll ni NsDataModel10.dll.

CONTENU DU PACKAGE
------------------
  Apply-123DFix.ps1   patcheur auto-verifiant (hash in/out)
  Install-123DFix.cmd installation admin
  Remove-123DFix.cmd  rollback
  README.txt          ce fichier

Aucun octet Autodesk n'est distribue : le script lit la DLL
originale de l'utilisateur et n'applique que les modifications.
================================================================
