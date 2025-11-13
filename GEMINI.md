# Project Overview

This repository is a collection of PowerShell scripts and a C# utility designed for various administrative and development tasks, with a focus on Microsoft Dynamics 365 and Azure DevOps.

## Key Components

### PowerShell Scripts

The `.ps1` files provide automation for a range of tasks. Here are some of the key scripts and their functions:

* **`ADO-Get-WorkItems.ps1`**: Fetches work items linked to a specific Azure DevOps pull request. It requires a `DevOpsAzureREST.config.json` file for API configuration.
* **`D365...` scripts**: A set of scripts for interacting with Microsoft Dynamics 365 environments, such as `D365ListEnumNameAndValueFromXML.ps1` which extracts data from D365 XML files.
* **`CopyFilesFromXppProject.ps1`**: Copies files from a Dynamics 365 X++ project structure.
* **`SQL-...` scripts**: A collection of scripts for database operations like backup, restore, and cleaning (`SQL-BackupDB.ps1`, `SQL-RestoreDB.ps1`, etc.).
* **`InstallPowerShell_V_7.5.0_FinalVersion.ps1`**: A script to automate the download and installation of PowerShell 7.5.0. See `ScriptPowerShellV7.md` for usage instructions.

### C# Utility: EncryptPassRDP

* **Purpose**: A command-line application to encrypt passwords for use in RDP connection files.
* **Location**: `EncryptPassRDP/`
* **Usage**:
  * To build the project: `dotnet build EncryptPassRDP/EncryptPassRDP.csproj`
  * To run the application: `dotnet run --project EncryptPassRDP/EncryptPassRDP.csproj`

## How to Use the Scripts

### PowerShell

1. **Configuration**: For scripts that interact with Azure DevOps, a configuration file (e.g., `DevOpsAzureREST.config.json`) is used. You can specify its path using the `-ConfigFilePath` parameter. The Personal Access Token (PAT) within this configuration file can be a plain text token or reference an environment variable using the format `${env:YOUR_ENV_VAR_NAME}` for enhanced security.
2. **Execution**: Run the scripts from a PowerShell 7 terminal. Most scripts accept parameters. Use `Get-Help .\<script-name>.ps1 -Full` to see the available parameters and examples.

    For example, to get work items for a pull request:

    ```powershell
    .\ADO-Get-WorkItems.ps1 -pullRequestId 12345 -ConfigFilePath ".\my-custom-config.json"
    ```

### Development Conventions

* **PowerShell Style**: Scripts are written to be modular and reusable, with clear parameter definitions and error handling.
* **C# Style**: The C# project follows standard .NET conventions.

## Git Ignore

The `.gitignore` file has been updated to ignore all `.json` files, preventing sensitive configuration data (like PATs) from being accidentally committed.
