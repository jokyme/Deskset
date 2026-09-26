# Security

## Skins are programs

A Rainmeter skin is more than a picture. Depending on what it uses, a skin can:

- run Lua scripts (Deskset runs them with memory, time and library limits);
- download web pages and feeds (WebParser);
- open files, folders, web pages and apps when you click it;
- run shell commands (the RunCommand plugin) and read or write files (FileView, notes and settings skins).

Deskset runs skins with the permissions you give it, just as Rainmeter does on Windows. Only install skins from
sources you trust, and look at a skin's files if you are unsure what it does.

## Reporting a vulnerability

Please report security problems privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue for them.

Examples of what we want to hear about:

- a way for a skin to escape the Lua limits or run code that its documented options do not allow;
- a way for a skin to act without the user interaction it documents (for example running a command without a click);
- installing a `.rmskin`, `.zip` or folder writing files outside the skins and layouts folders;
- anything that lets a web page or feed loaded by a skin execute code.

Security fixes go into the latest release.
