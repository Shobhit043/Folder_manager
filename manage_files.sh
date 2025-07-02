#!/usr/bin/bash

# Category labels
categories=(images videos audio documents archives code executables fonts certificates ebooks design datafiles)

# Extensions for each category (index aligned with categories array)
extensions=(
  "jpg jpeg png gif bmp tiff webp heic svg ico"                         # images
  "mp4 mkv avi mov wmv flv webm mpeg 3gp mts"                           # videos
  "mp3 wav flac aac ogg m4a wma alac opus aiff"                         # audio
  "pdf doc docx ppt pptx xls xlsx odt ods odp rtf txt md"              # documents
  "zip rar 7z tar gz bz2 xz iso tgz lz"                                 # archives
  "py js ts java c cpp cs rb php html css bat pl swift kt go rs sh ipynb"    # code
  "exe msi apk app deb rpm bin run dmg sh"                             # executables
  "ttf otf woff woff2 eot fon"                                         # fonts
  "pem key cer crt pfx p12"                                            # certificates
  "epub mobi azw3 fb2 djvu"                                            # ebooks
  "psd ai eps svg xd sketch dwg dxf"                                   # design
  "log json xml csv yaml yml tsv db sqlite"                            # datafiles
)


move_file() {
  File=$1 # Current input file
  PWD=$2 # by default manage all the files in current directory only
  ext="${File##*.}"  # extension of the input file

  for i in "${!categories[@]}"; do # ! return index value instead of actual value
    for e in ${extensions[$i]}; do
      if [[ "$ext" == "$e" ]];then
         # Get category to the which the file extension belongs
         DirName=${categories[$i]} 

         # Current path of the file
         FilePath="$PWD/$File"

         # Path of the directory to which file would be moved 
         DirPath="$PWD/$DirName/"

         # Creating directory incase not present
         mkdir -p $DirPath 

         # Moving the file to the directory
         mv "$FilePath" "$DirPath"
         return
      fi
    done
  done

  # handle the case where no extension is found
  DirName="others"
  FilePath="$PWD/$File"
  DirPath="$PWD/$DirName/"
  mkdir -p $DirPath 
  mv "$FilePath" "$DirPath"

  return
}



# directory where script would take action
PWD="/home/shobhit/Downloads/"

while true; do
  # create Files array containing all file names
  IFS=$'\n' read -r -d '' -a Files < <(  ls $PWD -p | grep -v /  && printf '\0' )

  for item in "${Files[@]}"
    do
      move_file "$item" "$PWD"
    done

    sleep 0.5 # Sleep for 0.5 seconds before the next check
done
