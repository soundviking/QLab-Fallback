# Validation Build5.13-test — 17 septembre 2026

- Compilation Intel x86_64 et Apple Silicon arm64, macOS 14 minimum ; application universelle signée localement et vérifiée.
- 294 contrôles automatisés réussis : 46 intégrité/protocole, 99 GO/OSC/médias/archives, 6 signatures de workspace, 116 intégration avec QLab simulé, 27 transfert binaire.
- 14 scripts AppleScript compilés avec le dictionnaire du QLab installé. Aucune cue du spectacle exécutée pendant ces validations.
- Nouveau transport testé de fichier à fichier via TCP local sur 128 Mio + 3 octets, deux passages, SHA-256 identique. Mesures finales : 2 791 et 2 845 Mo/s sur ce Mac en boucle locale avec cache système ; ce ne sont pas des mesures Ethernet entre deux Macs et elles ne prédisent pas le débit des disques distants.
- Chemin réel de contrôle MASTER/BACKUP, connexion binaire, écriture de 32 Mio + 17 octets puis vérification SHA-256 exercés ensemble. Une empreinte volontairement fausse est refusée avant extraction, le MASTER reçoit le refus, aucun état prêt n’est accordé ; heartbeat conservé.
- Jeton incorrect, EOF prématurée, taille excédentaire, source tronquée et annulation testés. Une seule complétion par extrémité.
- Statut BACKUP : historique d’erreurs avec état courant prêt → vert ; heartbeat absent, isolation absente, préparation absente ou version non acquittée → orange ; déconnexion → rouge. Retour manuel du son et sélection bidirectionnelle passent les tests existants.
- Inventaire SHA-256 de la Build5.12 vérifié inchangé ; ressources et animations d’aide identiques.

Objectif terrain : au moins 60 Mo/s pendant la copie sur la liaison mesurée à 79,4 Mo/s. À vérifier sur les deux Macs avec une archive assez grande. La préparation, l’extraction et la validation QLab ajoutent du temps au total. Le transport historique reste utilisé lorsqu’un des deux Macs est sur une ancienne version.
