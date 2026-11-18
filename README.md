# Sonos Control

Une application macOS légère pour piloter vos enceintes Sonos directement depuis la barre des menus.

> Projet indépendant et non affilié à Sonos, Inc.

## Fonctionnalités

- Détection automatique des enceintes Sonos sur le réseau local
- Affichage des groupes et de leurs membres
- Lecture et pause
- Affichage du morceau en cours et de sa pochette
- Réglage du volume d’un groupe
- Réglage individuel du volume de chaque enceinte
- Regroupement de toutes les enceintes
- Séparation d’un groupe
- Lancement automatique à l’ouverture de session
- Mise en cache des appareils pour accélérer les démarrages suivants

## Prérequis

- macOS 27.0 ou version ultérieure
- Xcode 27 ou version ultérieure
- Un Mac et des enceintes Sonos connectés au même réseau local

## Installation depuis les sources

1. Clonez le dépôt :

   ```bash
   git clone <URL_DU_DÉPÔT>
   cd SonosControl
   ```

2. Ouvrez `SonosControl.xcodeproj` dans Xcode.
3. Sélectionnez le schéma **SonosControl** et la destination **My Mac**.
4. Lancez l’application avec **⌘R**.

Aucune dépendance tierce n’est nécessaire.

## Utilisation

Après son lancement, Sonos Control apparaît dans la barre des menus de macOS.

1. Ouvrez le menu de l’application.
2. Sélectionnez un groupe Sonos.
3. Utilisez le bouton lecture/pause et les curseurs de volume.
4. Utilisez les boutons de l’en-tête pour regrouper ou séparer les enceintes.
5. Cliquez sur le bouton d’actualisation pour relancer la détection.

L’option **Lancer à l’ouverture de session** est disponible dans le menu des réglages de l’application. macOS peut demander une validation dans **Réglages Système > Général > Ouverture**.

## Fonctionnement

L’application est développée en Swift et SwiftUI. Elle communique directement avec les enceintes sur le réseau local :

- **SSDP** pour la découverte des appareils ;
- **UPnP** pour lire la topologie des groupes ;
- **SOAP** pour la lecture, la pause, le volume et la gestion des groupes.

Les informations restent sur le Mac et le réseau local. Aucun service cloud intermédiaire n’est utilisé par l’application.

## Dépannage

### Aucune enceinte n’apparaît

- Vérifiez que le Mac et les enceintes utilisent le même réseau local.
- Désactivez temporairement les VPN ou les règles de pare-feu qui bloquent le multicast UDP.
- Cliquez sur le bouton d’actualisation dans l’application.
- Vérifiez que l’accès au réseau local est autorisé pour l’application dans les réglages de macOS.

### Une commande échoue

La disponibilité de certaines commandes peut varier selon le modèle, la version du logiciel Sonos et la configuration du groupe. Actualisez les groupes puis réessayez.

## Structure du projet

- `ContentView.swift` — interface et état de l’application
- `SonosDiscoveryService.swift` — découverte SSDP des enceintes
- `SonosTopologyService.swift` — lecture des groupes Sonos
- `SonosControlService.swift` — commandes de lecture et de volume
- `LaunchAtLoginService.swift` — lancement à l’ouverture de session
- `SonosDeviceCache.swift` — cache local des appareils

## Contribuer

Les contributions sont les bienvenues. Avant de proposer une modification :

1. créez une branche dédiée ;
2. gardez les changements ciblés ;
3. vérifiez que le projet compile dans Xcode ;
4. ouvrez une pull request en décrivant le problème résolu.

## Licence

Aucune licence n’est actuellement fournie. Tous droits réservés par défaut.
