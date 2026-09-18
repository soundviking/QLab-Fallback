# Test sur deux Macs — Build5.13-test

1. Quitter les anciennes instances de Fallback, puis installer le package 5.13 sur les deux Macs. Conserver les anciennes versions et les dossiers existants.
2. Dans Réglages avancés → Réseau et débit, choisir la carte Ethernet avant activation sur chaque Mac. Activer le MASTER puis le BACKUP.
3. Cues arrêtées, lancer « Créer le fallback ». Relever la taille de l’archive, la vitesse moyenne pendant la copie et le temps total. L’objectif est au moins 60 Mo/s sur la liaison mesurée à 79,4 Mo/s ; il doit être confirmé sur les deux Macs. Une petite archive ne permet pas une mesure représentative. Les médias déjà présents restent réutilisés.
4. Attendre la validation : vérifier « Synchro OK » en vert sur fond noir dans les deux barres de menu et « BACKUP prêt à basculer : Oui ». Si orange, ouvrir le menu et relever la raison affichée.
5. Vérifier un GO par espace puis par bouton, Cake 1 et 1.5, et la sélection dans les deux sens. Le BACKUP doit rester silencieux grâce à l’isolation.

La vitesse de copie est distincte de la préparation de l’archive, de son extraction et de la validation QLab. Il est normal que ces étapes ajoutent du temps au total.

Diagnostic : ~/Library/Logs/QLab Fallback Build5.13-test/diagnostic.log. Les lignes « TRANSFERT BINAIRE envoyé » et « TRANSFERT BINAIRE reçu et écrit » donnent les mesures des deux côtés.
