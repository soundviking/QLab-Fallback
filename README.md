# QLab Fallback

QLab Fallback est une application macOS indépendante conçue pour améliorer la redondance PRIMARY/BACKUP avec QLab dans les environnements de spectacle vivant.

Le projet vise notamment à faciliter la synchronisation d’un workspace entre deux Macs, la réplication des GO, le failover vers un ordinateur BACKUP, l’isolation audio du BACKUP, le retour silencieux du PRIMARY, la reprise manuelle du son et la resynchronisation contrôlée.

## Statut du projet

Le logiciel est actuellement en phase bêta.

Version produit recommandée : `0.6.0-beta.1`  
Build : `514`

## Auteur

QLab Fallback a été conçu et développé par Antoine Clopier avec l’assistance de ChatGPT.

## Licence

Le code source est distribué sous la licence PolyForm Noncommercial 1.0.0.

Toute utilisation commerciale, intégration dans un produit ou service commercial, redistribution payante ou exploitation commerciale nécessite l’autorisation écrite préalable du titulaire des droits.

Voir `LICENSE.md`, `COMMERCIAL-LICENSE.md` et `CONTRIBUTING.md`.

## Indépendance vis-à-vis de Figure 53

QLab Fallback est un projet indépendant. Il n’est ni affilié à, ni approuvé par Figure 53.

QLab est un logiciel de Figure 53. Les noms et marques associés restent la propriété de leurs titulaires respectifs.

## Avertissement bêta

Le logiciel est en développement et doit être testé dans des conditions réelles avant toute utilisation critique en spectacle.

## Branche de revue — fiabilité et interface

Les changements en revue ne constituent pas une nouvelle release validée pour le spectacle.

- Détection QLab dès l'ouverture de Fallback, sans activation PRIMARY/BACKUP et sans ouvrir les réglages. La lecture des workspaces est asynchrone et n'envoie aucune commande audio.
- Le workspace choisi explicitement n'est pas remplacé par celui au premier plan.
- Le code OSC est masqué par défaut ; le bouton œil appartient à la fenêtre de réglages.
- Langue dans **QLab Fallback → Réglages** : système, français, anglais, allemand ou espagnol. Le choix est mémorisé. PRIMARY et BACKUP sont identiques dans toutes les langues.
- Menu **Aide** : guide, tutoriel QLab et tutoriel Fallback. Schémas natifs légers, sans animation périodique ni téléchargement.
- À la première activation BACKUP, choisir le dossier de réception. Fallback vérifie l'écriture et mémorise un signet macOS. Le chemin ouvre le Finder ; le changement est verrouillé tant que BACKUP est actif. Les projets existants ne sont pas déplacés. Les nouvelles révisions Live Mirror vont dans `Revisions` sous ce dossier.
- La présence du heartbeat réseau et la santé QLab du PRIMARY sont séparées. Une annonce QLab indisponible reste bloquante jusqu'à un nouveau heartbeat sain.
- Un test audio admissible peut être converti en prise de relais. Si le miroir n'est plus prêt à son expiration après perte PRIMARY, le son déjà ouvert est conservé sans déclarer une bascule validée. Le retour PRIMARY ne provoque pas de remute automatique.

## Compiler et vérifier

Sur macOS avec Xcode et le dictionnaire AppleScript de QLab installé :

```sh
bash Packaging/validate.sh
```

La commande compile Apple Silicon et Intel, exécute les suites locales et crée `Artifacts/Review/QLab Fallback Review.app`, signée localement. Elle n'installe rien et ne remplace pas le package de référence. Les journaux sont dans `Validation/final`.

La référence publiée reste `aaf4173` / `0.6.0-beta.1` / build `514`. Voir [la revue et ses limites](Docs/REVIEW-2026-09-19.md) et [le protocole deux Macs](LIRE-AVANT-TEST.md).
