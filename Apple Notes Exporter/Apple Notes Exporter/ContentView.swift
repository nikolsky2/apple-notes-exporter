//
//  ContentView.swift
//  Apple Notes Exporter
//
//  Created by Konstantin Zaremski on 2/23/23.
//

import SwiftUI
import Foundation
import UniformTypeIdentifiers

struct MenuItem: Identifiable {
    let id = UUID()
    let title: String
    let action: () -> Void
}

/**
 Struct that represents an exported Apple Note
 */
struct Note {
    var ID: String
    var title: String
    var content: String
    var creationDate: String
    var modificationDate: String
    var folder: String
    
    init(ID: String, title: String, content: String, creationDate: String, modificationDate: String, folder: String) {
        self.ID = ID
        self.title = title
        self.content = content
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.folder = folder
    }
}

extension NSAppleEventDescriptor {
    func toStringArray() -> [String] {
        guard let listDescriptor = self.coerce(toDescriptorType: typeAEList) else {
            return []
        }
        
        return (0..<listDescriptor.numberOfItems)
            .compactMap { listDescriptor.atIndex($0 + 1)?.stringValue }
    }
}

struct AppleScript {
    /**
     Runs an AppleScript script string with an expected string array result.
     */
    func stringArray(script: String) -> [String] {
        // Create the new NSAppleScript instance
        if let scriptObject = NSAppleScript(source: script) {
            // Error dictionary
            var errorDict: NSDictionary? = nil
            // Execute the script, adding to the errorDict if there are errors
            let resultDescriptor = scriptObject.executeAndReturnError(&errorDict)
            // If there are no errors, return the resultDescriptor after converting it to a string array
            if errorDict == nil {
                return resultDescriptor.toStringArray()
            }
        }
        // Return an empty string if no result
        return []
    }
}

func getNotesUsingAppleScript(noteAccountName: String) -> [Note] {
    // Script to export the notes from the current account
    let exportScript = """
        set noteList to {}
        tell application "Notes"
            repeat with theAccount in accounts
                if name of theAccount as string = "\(noteAccountName)" then
                    set chosenAccount to theAccount
                end if
            end repeat
            repeat with currentNote in notes of chosenAccount
                set noteLocked to password protected of currentNote as boolean
                if not noteLocked then
                    -- Get properties of the not if it is not locked
                    set modificationDate to modification date of currentNote as string
                    set creationDate to creation date of currentNote as string
                    set noteID to id of currentNote as string
                    set noteTitle to name of currentNote as string
                    set noteContent to body of currentNote as string
                    -- Get the path of the note internally to Apple Notes
                    set currentContainer to container of currentNote
                    set internalPath to name of currentContainer
                    repeat until name of currentContainer as string = name of default account as string
                        set currentContainer to container of currentContainer
                        if name of currentContainer as string ≠ name of default account then
                            set internalPath to (name of currentContainer & "/" & internalPath)
                        end if
                    end repeat
                    -- Build the object
                    set noteListObject to {noteID,noteTitle,noteContent,creationDate,modificationDate,internalPath}
                    -- Add to the list
                    set end of noteList to noteListObject
                end if
            end repeat
        end tell
        return noteList
    """
    
    // Error handling
    var errorDict: NSDictionary? = nil
    // Execute the script, adding to the errorDict if there are errors
    let script: NSAppleScript = NSAppleScript(source: exportScript)!
    let resultDescriptor = script.executeAndReturnError(&errorDict)
    // If there are errors, return and do nothing
    if errorDict != nil {
        return []
    }
    
    // Take action with the resulting Apple Event desciptor in order to export and format the notes
    let listDescriptor = resultDescriptor.coerce(toDescriptorType: typeAEList)!
    
    // Empty array of output notes
    var notes: [Note] = []
    
    // Iterate through the typeAEList
    for listIndex in 0 ... listDescriptor.numberOfItems {
        // This record is just a list of strings in a particular order since I could not figure out typeAERecord
        guard let recordDescriptor = listDescriptor.atIndex(listIndex)?.coerce(toDescriptorType: typeAEList) else {
            // If it doesn't work, just skip it for now
            continue
        }
        // Create a new note from the AppleScript object based on the indexes of the values provided in the Apple Event descriptor
        //   {noteID,noteTitle,noteContent,creationDate,modificationDate,internalPath}
        //   {
        //      noteID,             1
        //      noteTitle,          2
        //      noteContent,        3
        //      creationDate,       4
        //      modificationDate,   5
        //      internalPath        6
        //  }
        let newNote = Note(
            ID: recordDescriptor.atIndex(1)?.stringValue ?? "",
            title: recordDescriptor.atIndex(2)?.stringValue ?? "",
            content: recordDescriptor.atIndex(3)?.stringValue ?? "",
            creationDate: recordDescriptor.atIndex(4)?.stringValue ?? "",
            modificationDate: recordDescriptor.atIndex(5)?.stringValue ?? "",
            folder: recordDescriptor.atIndex(6)?.stringValue ?? ""
        )
        // Add the note to the list of notes
        notes.append(newNote)
    }
    
    // Return the list of Apple Notes
    return notes
}

struct ContentView: View {
    func exportNotes() {
        // Validate
        if outputFilePath == "Select output file location" {
            showNoOutputSelectedAlert = true
            return
        }
        if selectedNotesAccount == "" {
            return
        }
        
        // Open the progress window since we are starting a long process.
        showProgressWindow = true
        // Do the export in the global DispatcheQueue as an async operation so that it does not block the UI
        DispatchQueue.global().async {
            // Get notes from the selected account using AppleScript (this takes a while)
            let notes = getNotesUsingAppleScript(noteAccountName: selectedNotesAccount)
            // Hide the progress window now that we are done
            showProgressWindow = false
        }
    }
    
    init() {
        self._selectedNotesAccount = State(initialValue: notesAccounts.first ?? "")
    }
    
    /**
     Select the output file location. It is a ZIP file in the directory of the user's choosing.
     */
    func selectOutputFile() {
        guard let documentURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        
        let savePanel = NSSavePanel()
        // Default file name of something like:   Apple Notes Export 2023-05-25.zip
        savePanel.allowedContentTypes = [UTType.zip]
        savePanel.nameFieldStringValue = "Apple Notes Export " + ISO8601DateFormatter().string(from: Date()).split(separator: "T")[0] + ".zip"
        
        if savePanel.runModal() == .OK, let exportURL = savePanel.url {
            self.outputFilePath = exportURL.path
            self.outputFileURL = exportURL
        }
    }
    
    // State of the interface and form inputs
    @State private var notesAccounts: [String] = AppleScript().stringArray(script: """
            set theAccountNames to {}
            tell application "Notes"
                repeat with theAccount in accounts
                    copy name of theAccount as string to end of theAccountNames
                end repeat
            end tell
            return theAccountNames
        """)
    @State private var selectedNotesAccount = ""
    @State private var selectedOutputFormat = "HTML"
    @State private var outputFilePath = "Select output file location"
    @State private var outputFileURL: URL?
    @State private var showProgressWindow: Bool = false
    @State private var showNoOutputSelectedAlert: Bool = false
    
    // Body of the ContentView
    var body: some View {
        VStack(alignment: .leading) {
            Text("Step 1: Select Notes Account")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Picker("Input", selection: $selectedNotesAccount) {
                ForEach(self.notesAccounts, id: \.self) { account in
                    Text(account).tag(account)
                }
            }.labelsHidden()
            
            Text("Step 2: Choose Output Document Format")
                .font(.title)
                .multilineTextAlignment(.leading).lineLimit(1)
            Picker("Output", selection: $selectedOutputFormat) {
                ForEach(["HTML","PDF","RTFD"], id: \.self) {
                    Text($0)
                }
            }.labelsHidden().pickerStyle(.segmented)
            
            Text("Step 3: Select Output File Destination").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            HStack() {
                Image(systemName: "info.circle")
                Text("Notes and folder structure are preserved in ZIP file for portability.")
            }
            HStack() {
                Image(systemName: "folder")
                Text(outputFilePath).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    selectOutputFile()
                } label: {
                    Text("Select")
                }.padding(.top, 7.0)
            }
            
            Text("Step 4: Export!").font(.title).multilineTextAlignment(.leading).lineLimit(1)
            Button(action: {
                exportNotes()
            }) {
                Text("Export").frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            
            Text("Apple Notes Exporter v0.1 - Copyright © 2023 Konstantin Zaremski - Licensed under the [MIT License](https://raw.githubusercontent.com/kzaremski/apple-notes-exporter/main/LICENSE)")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.vertical, 5.0)
        }
        .frame(width: 500.0, height: 320.0)
        .padding(10.0)
        .sheet(isPresented: $showProgressWindow) {
            ExportProgressView()
        }
        .alert(isPresented: $showNoOutputSelectedAlert) {
            Alert(
                title: Text("No Output File Chosen"),
                message: Text("Please choose the location for the ZIP file containing the exported Apple Notes."),
                dismissButton: .default(Text("OK"))
            )
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
