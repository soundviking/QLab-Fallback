# Changelog

## Non publié — branche de revue

- Sécurisation test audio/failover et séparation heartbeat/santé QLab.
- Détection globale asynchrone, sélection workspace respectée.
- Éditeur OSC autonome dans la fenêtre de réglages.
- Dossier BACKUP natif, persistant et validé ; révisions au même emplacement.
- Catalogue Apple FR/EN/DE/ES, choix système/manuel et aide native multilingue.
- Terminologie PRIMARY/BACKUP ; protocole réseau historique conservé.
- Suppression des animations périodiques d’aide et des publications de version QLab identique.
- Tests ciblés et script de validation reproductible.

Validation spectacle sur deux Macs encore requise. Voir `Docs/REVIEW-2026-09-19.md`.

## 0.6.0-beta.1 — Build 514

### Évolutions récentes
- optimisation du Live Mirror ;
- augmentation de la taille des chunks de synchronisation ;
- préparation de la synchronisation pendant qu’une cue peut être active ;
- ajout / préparation d’une relance manuelle de synchronisation ;
- amélioration de la fenêtre Réglages avancés ;
- évolution vers une interface macOS plus native.

### Points validés à préserver
- transfert de projet rapide mesuré jusqu’à environ 105 Mo/s sur deux Macs ;
- GO via espace et bouton ;
- Cake 1 et Cake 1.5 ;
- isolation audio ;
- sélection bidirectionnelle ;
- retour silencieux du PRIMARY ;
- reprise manuelle du son.

### À revalider sur deux Macs
- vitesse réelle de resynchronisation ;
- synchronisation pendant lecture / pause ;
- relance manuelle ;
- cycles répétés de perte / retour PRIMARY ;
- comportement failover avec les optimisations récentes.
