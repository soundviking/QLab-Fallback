# État du projet

Version produit recommandée : `0.6.0-beta.1`  
Build : `514`

## Référence historique à conserver intacte
Build5.13-test

## Points validés à préserver
- transfert initial rapide ;
- GO via espace et bouton ;
- Cake 1 et Cake 1.5 ;
- isolation audio du BACKUP ;
- sélection bidirectionnelle ;
- failover ;
- retour silencieux du PRIMARY ;
- reprise manuelle du son.

## Contraintes permanentes
- sauvegarde préalable obligatoire ;
- ne jamais modifier directement une build de référence ;
- ne pas réinstaller les accès de contrôle de l’ordinateur ;
- distinguer les tests réellement exécutés des tests à effectuer sur deux Macs ;
- préserver les protections audio et failover.

Les validations terrain PRIMARY/BACKUP sur deux Macs restent à finaliser pour cette version bêta.

## Travail en revue

La branche `codex/show-reliability-localization` part de `aaf4173`. Les références publiées et `main` restent intactes. Le compte rendu de la passe et les limites de validation sont dans `REVIEW-2026-09-19.md`.
