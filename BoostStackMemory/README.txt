================================================================
123D Design - Boost reserve de pile (~9,5 Mo -> 256 Mo)
================================================================

PROBLEME CORRIGE
----------------
123D Design compile ses threads avec une reserve de pile de
seulement ~9,5 Mo (champ PE SizeOfStackReserve = 0x989680).
Les operations lourdes du noyau geometrique (booleens,
recursions profondes, gros buffers alloues sur la pile)
peuvent depasser cette limite -> stack overflow -> crash
immediat.

CORRECTIF APPLIQUE
------------------
Reecriture du champ SizeOfStackReserve dans l'en-tete PE de
"123D Design.exe" :

    0x989680 (10 000 000 octets ~ 9,5 Mo) -> 0x10000000 (256 Mo)

Il ne s'agit PAS de memoire consommee en plus : Windows
reserve seulement l'espace d'adressage virtuel par thread ;
les pages physiques ne sont commises que si la pile grossit
reellement. Correctif communautaire connu (123D / Meshmixer).

Le script localise le champ dynamiquement via l'en-tete PE
(e_lfanew -> optional header PE32+ -> offset 0x48) plutot
qu'avec un offset en dur : il refuse toute cible non
conforme.

SECURITE
--------
  * Patche uniquement si la valeur actuelle est 0x989680
    (valeur d'origine Autodesk). Sinon : ABORT, jamais de
    patch a l'aveugle.
  * Backup automatique : "123D Design.exe.orig" a cote de
    l'exe (cree une seule fois, jamais ecrase).
  * Relecture et verification du champ apres ecriture.
  * Le rollback verifie que le backup est bien un PE32+ avec la reserve
    d'origine et qu'il ne differe du fichier courant que sur ce champ.
  * Si le reserve est deja a 256 Mo sans backup .orig, le script avertit
    que le rollback autonome n'est pas disponible.
  * Aucun octet Autodesk distribue : le script lit l'exe de
    l'utilisateur et n'applique que la modification.

INSTALLATION
------------
  Install-BoostStackMemory.cmd   (demande les droits admin
                                  automatiquement)

  ou manuellement, en PowerShell admin :
    .\Apply-BoostStackMemory.ps1
    .\Apply-BoostStackMemory.ps1 -InstallDir "D:\Autodesk\123D Design"

DESINSTALLATION
---------------
  Remove-BoostStackMemory.cmd    (restaure 123D Design.exe.orig)

  ou : .\Apply-BoostStackMemory.ps1 -Restore

NOTES
-----
  * Complementaire du patch "null activeCommand" (CrashFix) :
    celui-ci corrige les depassements de pile, l'autre les
    dereferencements de pointeur nul. Les deux coexistent
    sans conflit (fichiers differents : .exe vs .dll). Le premier patch
    qui augmente la reserve garde la sauvegarde proprietaire : utilisez
    son script Remove pour revenir a l'executable original.
  * Le meme patch est aussi applique par la section
    "exe stack-reserve fix" de Apply-123DFix.ps1 ; s'il est
    deja en place, ce script affichera "Already patched".
  * Fermez 123D Design avant d'appliquer ou de restaurer le patch.

CONTENU DU PACKAGE
------------------
  Apply-BoostStackMemory.ps1   patcheur auto-verifiant
  Install-BoostStackMemory.cmd installation admin
  Remove-BoostStackMemory.cmd  rollback
  README.txt                   ce fichier
================================================================
