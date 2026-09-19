# Titre

Sécuriser failover/test audio et ajouter détection globale, dossier BACKUP et aide multilingue

# Description prête pour une PR brouillon

Cette passe corrige la perte de disponibilité QLab masquée par un ancien heartbeat et la contradiction qui empêchait la conversion d'un test audio BACKUP en failover. Une sortie déjà ouverte n'est plus remutée à l'expiration du test après perte PRIMARY, sans déclarer une bascule validée lorsque les autres protections ne sont pas satisfaites.

Elle ajoute la détection QLab indépendante des rôles et fenêtres, conserve le workspace sélectionné, corrige l'état du bouton œil dans les réglages, rend le dossier BACKUP sélectionnable et persistant, et introduit un catalogue Apple FR/EN/DE/ES avec choix système/manuel et cinq pages d'aide visuelle native. Les libellés utilisent PRIMARY/BACKUP ; les trames réseau restent compatibles. Les changements sont organisés en lots, sans refonte du moteur.

Validation : compilation arm64 et x86_64 sans avertissement ; 306 contrôles intégrité/protocole/GO/OSC/signatures/transfert réussis ; nouveaux tests découverte, dossier, localisation et durée de vie réussis ; 16 scripts AppleScript compilés ; application de revue signée localement. Les publications de version QLab identique passent de 5 000 à 0 pour 1 000 évaluations.

Voir [le compte rendu complet et la liste exacte des fichiers](REVIEW-2026-09-19.md). Validation physique sur deux Macs/QLab et interaction UI réelle encore requises. Les fixtures des tests QLab historiques ne sont pas disponibles ; certains diagnostics techniques dynamiques restent dans leur langue source. Aucun gain de démarrage à froid ni validation Instruments complète n'est revendiqué.

À conserver en brouillon jusqu'à revue et validation terrain. Aucune fusion automatique et aucune installation de la version de revue.

---

Base : `main` ; branche : `codex/show-reliability-localization`.

La branche est publiée. La création automatique de la PR a été refusée par l'intégration GitHub : HTTP 403, `Resource not accessible by integration`. Aucune PR n'a été créée.

[Ouvrir la comparaison et créer le brouillon](https://github.com/soundviking/QLab-Fallback/compare/main...codex%2Fshow-reliability-localization?expand=1)
