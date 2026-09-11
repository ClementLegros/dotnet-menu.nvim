# dotnet-menu.nvim

Un petit menu .NET pour Neovim : solutions, projets, fichiers, références
projet et packages NuGet — et le renommage / déplacement de fichiers C# qui
emmène avec lui le type, le namespace et les `using`, dans toute la solution.

Avec [oil.nvim](https://github.com/stevearc/oil.nvim), les mêmes actions se
déclenchent directement quand on crée, renomme, déplace ou supprime un `.cs`
dans oil, sans passer par le menu.

Interface en français.

## Prérequis

- **Neovim ≥ 0.11** (développé et testé sur 0.12).
- **SDK .NET** : `dotnet` dans le PATH.
- **roslyn_ls**, pour renommer / déplacer et pour la vérification avant
  suppression. Le plugin s'appuie sur un client LSP nommé `roslyn_ls`, celui de
  la spec [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig) :

  ```sh
  dotnet tool install --global roslyn-language-server --prerelease
  ```

  ```lua
  vim.lsp.enable("roslyn_ls")
  ```

  Le client `roslyn` de roslyn.nvim n'est pas pris en charge.
- **oil.nvim** (facultatif) pour les actions déclenchées depuis oil.

## Installation

Avec `vim.pack` (Neovim 0.12) :

```lua
vim.pack.add({ "https://github.com/ClementLegros/dotnet-menu.nvim" })
require("dotnet-menu").setup()
```

Avec lazy.nvim :

```lua
{ "ClementLegros/dotnet-menu.nvim", lazy = false, opts = {} }
```

**Pas de lazy-loading** : le renommage attend le signal « solution chargée »
que roslyn_ls envoie quelques secondes après son démarrage, et seul un plugin
déjà initialisé à ce moment-là peut le voir.

## Configuration

Valeurs par défaut :

```lua
require("dotnet-menu").setup({
    keymap = "<leader>n",      -- touche du menu (mode normal) ; false pour aucune
    oil = true,                -- réagir aux opérations enregistrées dans oil
    roslyn_diagnostics = true, -- corriger les erreurs qui restent après un ajout
                               -- de fichier (voir plus bas)
})
```

La commande `:Dotnet` ouvre aussi le menu.

## Le menu

| Touche | Action |
|--------|--------|
| `s` | Nouvelle solution (`.slnx` par défaut, `.sln` au choix) |
| `p` | Nouveau projet — 7 templates courants + le catalogue complet |
| `a` | Ajouter au `.sln` les projets présents sur disque mais absents |
| `f` | Nouveau fichier — class / interface / record / enum / struct |
| `R` | Renommer / déplacer le fichier `.cs` courant — type et namespace suivent, partout |
| `r` | Référence projet-à-projet |
| `n` | Package NuGet (recherche sur nuget.org) |

Tout passe par la CLI `dotnet` — pas de démon, pas d'analyse MSBuild — sauf le
renommage / déplacement, qui passe par roslyn_ls. Les champs de création
acceptent un **chemin** et pas seulement un nom — `src/Api` crée le projet
`Api` sous `src/`, `Services/Billing/Invoice` crée les dossiers et y place
`Invoice.cs`.

Deux endroits font mieux que la CLI, délibérément :

- **Le namespace.** `dotnet new class` écrit `namespace <RacineDuProjet>;` en
  ignorant les dossiers, sans option pour corriger, et avec un BOM. Le fichier
  est donc écrit directement, avec le namespace dérivé de l'arborescence.
- **Les cycles de références.** `dotnet add reference` accepte une référence
  circulaire sans broncher (exit 0) et le build casse ensuite avec `MSB4006`.
  Le menu n'affiche que les projets qui ne peuvent pas déjà atteindre la source,
  transitivement.

## Renommer / déplacer un fichier

roslyn_ls ne réagit aux renommages de fichiers que pour les `*.razor` : un
simple déplacement de `Foo.cs` laisserait la classe, et tout ce qui l'utilise,
sous l'ancien nom et l'ancien namespace. Le menu `R` (qui accepte un nom ou un
chemin relatif au fichier : `Bar`, `Models/Bar`, `../Services/Bar`) et oil
passent donc par roslyn_ls :

1. **Nom changé** : le type est renommé (`textDocument/rename`, toute la
   solution) tant que le fichier est encore à son ancien chemin.
2. Le fichier est déplacé.
3. **Dossier changé** : le namespace suit, via la refactorisation « Change
   namespace » de roslyn, qui ajoute aussi les `using` nécessaires — chez les
   appelants, et dans le fichier déplacé s'il utilisait des voisins de son
   ancien dossier. Proposée seulement une fois le projet rechargé (~2 s) : elle
   est attendue en tâche de fond.

Les fichiers modifiés sont enregistrés.

- **Attente du chargement.** Avant d'avoir chargé la solution, roslyn_ls répond
  quand même, mais avec le seul fichier courant — sans erreur (mesuré). Le
  renommage attend donc `workspace/projectInitializationComplete`.
- **Pas de type du même nom** (`Program.cs`, fichier à plusieurs types) : seul
  le fichier est renommé, et le message le dit.
- **Buffer avec des modifications en cours** : le renommage y est appliqué mais
  le buffer n'est pas enregistré — il est nommé dans un avertissement.
- **Namespace choisi à la main** : il n'est changé que s'il suivait l'ancien
  dossier. Sinon il est conservé, et le message le dit.

## Depuis oil, sans le menu

Les opérations enregistrées dans oil (`:w`) déclenchent directement l'action
correspondante, pour un `.cs` situé dans un projet. Le renommage, le
déplacement et la suppression passent par roslyn_ls, et seulement s'il tourne
déjà pour cette solution — aucun serveur n'est démarré pour l'occasion :

| Dans oil | Effet |
|----------|-------|
| Créer `Invoice.cs` | Fichier vide rempli : namespace des dossiers + `public class Invoice` (`interface` pour `IInvoice…`) |
| Renommer `Foo.cs` → `Bar.cs` | Type `Foo` renommé en `Bar` dans toute la solution, avant qu'oil ne déplace le fichier |
| Déplacer `Foo.cs` (couper / coller) dans `Models/` | Namespace → `…Models`, `using` ajoutés où il faut |
| Supprimer `Foo.cs` | Avertissement si `Foo` est encore utilisé ailleurs ; le buffer du fichier supprimé est fermé |

Branché sur les événements `OilActionsPre` / `OilActionsPost`. Un `.cs` hors de
tout projet (ou un nom qui n'est pas un identifiant, `Invoice.Validation.cs`)
est laissé tel quel.

## Diagnostics roslyn (`roslyn_diagnostics`)

Quand un fichier est ajouté au projet (création, renommage, déplacement), les
buffers déjà ouverts qui utilisent son type gardent une erreur CS0246 jusqu'à
un `:e` — alors que le serveur, lui, connaît déjà le type. En cause : à chaque
`workspace/diagnostic/refresh`, Neovim ne redemande que les diagnostics
« workspace », pas ceux de chaque document ouvert. Avec cette option, le plugin
redemande aussi ces derniers. Le handler éventuellement défini dans ta propre
config est conservé : il est enveloppé, pas remplacé.

## Limites connues

- Testé sous Linux (Neovim 0.12, roslyn-language-server 5.12). Windows : pas
  encore testé.
- Déplacer un **dossier** entier ne met pas à jour les namespaces des fichiers
  qu'il contient.
- Copier un `.cs` dans oil ne renomme pas le type de la copie.

## Licence

MIT
