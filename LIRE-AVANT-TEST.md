# Test sur deux Macs — Build5.13-test

1. Quitter les anciennes instances de Fallback, puis installer le package 5.13 sur les deux Macs. Conserver les anciennes versions et les dossiers existants.
2. Dans Réglages avancés → Réseau et débit, choisir la carte Ethernet avant activation sur chaque Mac. Activer le PRIMARY puis le BACKUP.
3. Cues arrêtées, lancer « Créer le fallback ». Relever la taille de l’archive, la vitesse moyenne pendant la copie et le temps total. L’objectif est au moins 60 Mo/s sur la liaison mesurée à 79,4 Mo/s ; il doit être confirmé sur les deux Macs. Une petite archive ne permet pas une mesure représentative. Les médias déjà présents restent réutilisés.
4. Attendre la validation : vérifier « Synchro OK » en vert sur fond noir dans les deux barres de menu et « BACKUP prêt à basculer : Oui ». Si orange, ouvrir le menu et relever la raison affichée.
5. Vérifier un GO par espace puis par bouton, Cake 1 et 1.5, et la sélection dans les deux sens. Le BACKUP doit rester silencieux grâce à l’isolation.

La vitesse de copie est distincte de la préparation de l’archive, de son extraction et de la validation QLab. Il est normal que ces étapes ajoutent du temps au total.

Diagnostic : ~/Library/Logs/QLab Fallback Build5.13-test/diagnostic.log. Les lignes « TRANSFERT BINAIRE envoyé » et « TRANSFERT BINAIRE reçu et écrit » donnent les mesures des deux côtés.

## Complément obligatoire pour la branche de revue

Utiliser une copie de spectacle et un routage audio contrôlé. Conserver la version de référence.

1. Sur chaque Mac, essayer QLab avant Fallback puis Fallback avant QLab ; ouvrir ensuite un workspace, le fermer, le rouvrir, quitter et relancer QLab. Refaire rôle inactif et réglages fermés. Deux workspaces ouverts : sélectionner celui qui n'est pas au premier plan et activer PRIMARY ; confirmer son identité.
2. Ouvrir les réglages : afficher/masquer le code, le modifier puis enregistrer. Fermer/réouvrir la fenêtre : code de nouveau masqué. Vérifier la langue système puis FR/EN/DE/ES, relancer Fallback et contrôler la mémorisation et l'aide.
3. Choisir un dossier BACKUP avec espaces/accents et un volume externe. Relancer Fallback, vérifier le Finder, l'écriture réelle et le chemin des révisions. Débrancher le volume et vérifier le refus sans repli silencieux vers Documents. Changement impossible en BACKUP actif. Vérifier que les copies existantes restent intactes.
4. En veille validée, lancer le test audio puis couper PRIMARY à différents moments, y compris près de l'expiration. BACKUP ne doit pas être remuté ; vérifier l'acquittement d'ouverture audio et la continuité réelle sur les sorties physiques.
5. Répéter avec miroir non prêt : aucun faux état prêt/actif ; une sortie déjà ouverte ne doit pas être coupée automatiquement. Vérifier le message d'erreur et le retour manuel après réalignement.
6. PRIMARY reste sur le réseau mais QLab est arrêté : heartbeat réseau présent, QLab PRIMARY indisponible, aucune restauration depuis un ancien heartbeat sain. Relancer QLab ; le retour PRIMARY ne ferme jamais automatiquement BACKUP.
7. Vérifier GO, PANIC, lecture, pause, sélection bidirectionnelle, médias SHA-256, mauvais workspace, miroir non acquitté, mute manuel conservé et retour audio coordonné. Répéter avec perte réseau pendant transfert puis pendant reprise manuelle.
8. Mesurer durée de lancement, activité au repos pendant dix minutes, latence de bascule détection → confirmation audio, débit réseau, préparation/extraction/hash/rechargement. Observer les fuites avec Instruments sur plusieurs cycles.

Les tests QLab réels historiques nécessitent des fixtures locales non incluses dans le dépôt. Ne jamais remplacer leurs chemins par ceux d'un spectacle utilisateur.
