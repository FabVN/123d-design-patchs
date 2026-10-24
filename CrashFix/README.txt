================================================================
123D Design - Correctif crash "null activeCommand" (v12)
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

REGRESSION v4 CORRIGEE EN v5/v6
-----------------------------
Effet de bord constate : apres un Snap, l'application restait bloquee en
mode selection de faces/aretes (ajout/retrait comme si Ctrl etait
maintenu, sur tous les objets). Deux mecanismes censes relancer la
commande Select abandonnaient quand activeCommand etait deja nul :

  * les trois branches SelectToolbar (hide, showall, HideSolids)
    sautaient tout leur bloc de relance -> corrige en v5 : le saut nul
    entre desormais juste apres destroy(), dans selectCommandId ->
    findCommandDefinitionById -> executeCommand ;
  * le slot Qt "exit mode" FUN_1800c5540 (QTSelectToolbar, appele par
    le QML quand le cadre de commande se ferme) retournait sans rien
    faire si activeCommand etait deja nul -> corrige en v6 : le JZ nul
    pointe vers 0xC566F, le bloc qui reconstruit le CommandContext et
    relance Select.

CAUSE RACINE REELLE (v7, NuBase10.dll)
--------------------------------------
Les v5/v6 corrigeaient les chemins UI, mais le blocage apparaissait
AVANT toute interaction : c'est le moteur de commandes lui-meme qui
laisse la pile vide sans relancer la commande par defaut.

Nu::CommandMgr::popStackingCommand() (NuBase10.dll, RVA 0x1645B0) :

  deactivate(top); endCommand(top, reason); pop;
  if (reason != 3 && pile non vide && nouveauTop != 0) {
      resumeCommand(nouveauTop); activate; postActivate;
  }
  // sinon : RIEN - pile vide -> activeCommand = 0

Or Snap se lance avec stackingBehavior == 1, ce qui fait
clearStackingCommands() au push : Select est retiree de la pile des
le lancement de Snap. A la fin de Snap, la pile est vide et
personne n'appelle launchDefaultSessionCommand(). Sans Select, le
filtre de picking faces/aretes installe par Snap continue de
recevoir les clics : selection additive "comme si Ctrl etait
maintenu", sur tous les objets.

PROGRESSION v8-v12 (NuBase10.dll)
---------------------------------
L'analyse en direct (sondes WriteProcessMemory + dumps ProcDump)
a montre que popStackingCommand n'etait qu'une des issues par
lesquelles la pile de commandes se vidait sans relance de la
commande par defaut. Couverture complete :

  * v8  : destroyCommand branche "commande suspendue" (0x1652DF)
          -> relance quand pile vide et reason != 3.
  * v9  : destroyCommand 3e branche (0x165309), commande ni
          suspendue ni sommet.
  * v10 : destroyCommand early-return (0x16524A), commande deja
          dans le set "destruction differee" (+0x68) - le chemin
          des CommitCommand / FusionSnapFaceCommand. Suppression
          du hook clearStackingCommands (recursion infinie) et
          ajout d'un flag anti-reentrance (.fix+0x1F0) autour de
          chaque appel a launchDefaultSessionCommand.
  * v11 : .fix rendue executable+lisible+inscriptible (0xE0000020),
          stub1 re-ecrit (un JNZ mal place corrompait cmp [rbx+0x20]
          depuis v7), garde session [mgr+0x10] dans les stubs.

CAUSE FINALE DU BLOCAGE "CTRL COINCE" (v12)
-------------------------------------------
Apres un Snap en echec, la commande par defaut relancee appelle
Nu::CommandContext::argumentAsPointer, qui fait un
boost::lexical_cast<unsigned long> sur un argument du contexte
dont la chaine n'est pas numerique -> bad_lexical_cast.
L'exception deroulait a travers CommandMgr::executeCommand EN
SAUTANT la decrementation du compteur de reentrance (mgr+0xC
restait a 1). Des lors, toute executeCommand suivante prenait le
chemin "nested" : begin+end immediat -> Select relancee mais
son SelectionState depile aussitot -> le filtre de picking
faces/aretes de la commande morte restait actif a jamais
(selection additive, orbit camera mort, molette = cadre de
selection, flyout absent).

La branche throw de lexical_cast<ulong> (appele uniquement par
argumentAsPointer) detruit maintenant le streambuf et retourne 0
= semantique "argument absent", deja geree par l'appelant.
Plus d'exception -> plus de fuite du compteur.
CORRECTIF APPLIQUE
------------------
Na123DUI10.dll (inchange depuis v6) :

  1. caveA  : chaine activeCommand->commandDefinition avec
     tests de null (5 sleds de predicats redirigents dessus)
  2. caveB  : garde "test r13,r13" pour le site du menu builder
  3. stubs  : 6 wrappers "jrcxz -> retourne 0 ; jmp [slot]"
     appliques aux 657 sites d'appel reels
  4. SelectToolbar : garde 3 appels directs a
     CommandBase::commandDefinition (RVA 0xCD313, 0xCD6EC, 0xCD89B)
  5. Slot "exit mode" FUN_1800c5540 : relance Select meme si
     activeCommand est deja nul

NuBase10.dll (nouveau en v7) :

  Une section ".fix" executable est ajoutee. Dans
  popStackingCommand, les 10 octets "mov rax,[rbx+0x28] ;
  cmp [rbx+0x20],rax ; jz epilogue" (RVA 0x164611) deviennent
  JMP stub + NOP. Le stub refait le test pile-vide :
    - pile non vide -> retour au chemin de reprise (0x16461B)
    - pile vide     -> call launchDefaultSessionCommand (0x165E30)
                       puis retour a l'epilogue (0x164672)
  Le cas reason == 3 (nettoyage/shutdown) est deja filtre en
  amont et ne declenche jamais la relance. launchDefaultSessionCommand
  tire CommandManagerDefaultCommandEvent ; l'abonne dans
  Na123DUI10.dll y inscrit SelectCmdDef ; executeCommand relance
  Select -> la selection d'elements normale est restauree.

La DLL originale est conservee dans Na123DUI10.dll.bak123d et
NuBase10.dll.bak123d.
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
  SHA256 patche v5: 11A5327153A2DA699DF16C41E7BED567
                    1157ACA0C92B9B0D3B9C9836468F0485
  SHA256 patche v6: 051AF352D2CC4E04BD3C906A8552ABA8
                    4286674D9F5B8D59B6C22215ED9B06F5
Uniquement la build exacte de NuBase10.dll :
  SHA256 original : 0DAEE4ABBE50016836095ACF646B75CD
                    F59719CE0CD6B7669EED83CE82A1F44B
  SHA256 patche v12: 96F8C96CCCE200D7E5B65E27E6BF6B3
                     921A32EEB7C5AD93355F98DB27DC0C76E
Le script VERIFIE les hash et refuse de patcher une autre
version (securite : jamais de patch a l'aveugle).
Le v12 sait mettre a niveau le v3, le v4, le v5, le v6 et les v7-v11 (la source
est le backup original). Il refuse de remplacer toute variante
personnalisee non reconnue.

La DLL actuellement installee sur cette machine peut avoir le hash
9DF6EFBDE0A3E2622BC07D692352FFF7C61EA8487AEF5F52E6A1AC3C3F6183AE :
elle contient en plus des modifications d'etat premium, absentes du patch
standard. L'installateur refuse de l'ecraser automatiquement.

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
  Remove-123DFix.cmd    (restaure les DLL et, s'il appartient a
                         CrashFix, le backup stack .bak123d-stack)

  ou : .\Apply-123DFix.ps1 -Restore
  Les anciennes installations ayant seulement 123D Design.exe.orig ont un
  backup partage ambigu; le rollback le laisse intact pour ne pas annuler
  un patch BoostStackMemory independant.

GENERER LA DLL SANS INSTALLER
-----------------------------
  .\Apply-123DFix.ps1 -OutputOnly C:\temp\Na123DUI10.dll
  Ecrit aussi NuBase10_patched.dll dans le meme dossier.
  -OutputOnly refuse la source et tout chemin dans le dossier d'installation
  123D. Choisir un dossier de sortie externe. Pour ne pas modifier le lanceur :
  -SkipExeStackFix. Pour ne pas modifier NuBase10.dll : -SkipNuBaseFix.
  -InstallDir doit pointer vers le dossier Applications\123D; le chemin du
  lanceur et de NuBase10.dll est derive deux niveaux plus haut.

LIMITES CONNUES
---------------
  * Fermer 123D Design avant installation ou restauration. Le script
    refuse de modifier les fichiers si le processus est actif.
  * Les backups dont le hash ou les champs PE ne sont pas conformes sont
    refuses (pas de restauration avec un backup suspect).
  * La relance du defaut ne couvre que la pile videe par
    popStackingCommand ; si la session n'a pas d'abonne
    CommandManagerDefaultCommand (adapter absent), l'etat "aucune
    commande" peut subsister - les gardes anti-crash restent en place.
  * D'autres sites null dereference non encore observes peuvent
    exister ; signaler tout nouveau crash avec l'adresse du
    module fautif (Event Viewer / procdump).
  * Le patch ne modifie pas NsDataModel10.dll.

CONTENU DU PACKAGE
------------------
  Apply-123DFix.ps1   patcheur auto-verifiant (hash in/out)
  Install-123DFix.cmd installation admin
  Remove-123DFix.cmd  rollback
  README.txt          ce fichier

Aucun octet Autodesk n'est distribue : le script lit les DLL
originales de l'utilisateur et n'applique que les modifications.
================================================================
