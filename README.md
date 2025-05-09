An actor based module to monitor your connect characters.  Still a work in progress, and currently geared towards emulated servers that have more HP's than RoF2 can show (thus, percentages).  
![switcher pic](https://github.com/user-attachments/assets/fd1d097f-ffcf-4d84-98d0-2dc33b6ffbbd)

The script must run on all characters to populate data.  Once it does, Characters in the same zone as you will appear in green, hps will show up in color patterns for %'s.  This integrates MyDPS by grimmier378, and alphabuff as refactored by Braniac.  I take no credit for their work, just a big thank you!

Left click on a character's name to bring them to the forefront, right click their name to target them.

Also adds broadcast commands:

/acaa <command> (e.g., /acaa /sit) this has everyone, including yourself perform the command (/sit)

/aca <command> (e.g. /aca /dance) will have everyone EXCEPT yourself perform the command (/dance)

/actell <character> <command> (e.g., /actell Foo /fight) and Foo will /fight!

Once I figure out ImGui better, I'll update it so you can toggle mana displays, toggle the buff section on/off, etc.
