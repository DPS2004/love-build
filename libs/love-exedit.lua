-- love-exedit
-- very, VERY WIP way to modify the .exe resources of the love source binary
-- currently just changes the ICON to the given icon image 

-- @TODO clean this mess up
-- @NOTE requires love, bit, love-icon

--[[

  usage to modify the icon of an exe:
    require('love-exedit')
    local modified_exe_data = love.exedit.updateIcon('path_to_exe', 'path_to_image')

]]

require('bit')
require('libs.love-icon')

local RESOURCE_TYPES = { 
  "CURSOR", "BITMAP", "ICON", "MENU", "DIALOG", "STRING", "FONTDIR", "FONT",
  "ACCELERATOR", "RCDATA", "MESSAGETABLE", "GROUP_CURSOR", "UNUSED_13",
  "GROUP_ICON", "UNUSED_15", "VERSION", "DLGINCLUDE", "UNUSED_18", "PLUGPLAY",
  "VXD", "ANICURSOR", "ANIICON", "HTML", "MANIFEST"
}
-- datatypes to use with readDataType
DATA_TYPES = {
  RESOURCE_DIRECTORY = {
    { 'Characteristics', 4 },
    { 'TimeDateStamp', 4 },
    { 'MajorVersion', 2 },
    { 'MinorVersion', 2 },
    { 'NumberOfNamedEntries', 2 },
    { 'NumberOfIdEntries', 2 }
  },
  RESOURCE_DIRECTORY_ENTRY = {
    { 'Name', 4 },
    { 'DataOffset', 4}
  },
  RESOURCE_DATA_ENTRY = {
    { 'DataOffset', 4 },
    { 'DataSize', 4 },
    { 'CodePage', 4 },
    { 'Reserved', 4 }
  },
  GROUP_ICON_HEADER = {
    { 'Reserved', 2 },
    { 'IdType', 2 },
    { 'IdCount', 2 }
  },
  GROUP_ICON_ENTRY = {
    { 'Width', 1 },
    { 'Height', 1 },
    { 'ColorCount', 1 },
    { 'Reserved', 1 },
    { 'Planes', 2 },
    { 'BitCount', 2 },
    { 'BytesInRes', 4 },
    { 'Id', 2 }
  },
  FIXED_FILE_INFO = {
    { 'Signature', 4 },
    { 'StrucVersion', 4 },
    { 'FileVersionMS', 4 },
    { 'FileVersionLS', 4 },
    { 'ProductVersionMS', 4 },
    { 'ProductVersionLS', 4 },
    { 'FileFlagsMask', 4 },
    { 'FileFlags', 4 },
    { 'FileOS', 4 },
    { 'FileType', 4 },
    { 'FileSubtype', 4 },
    { 'FileDateMS', 4 },
    { 'FileDateLS', 4 },
  }
}

-- reads data from the index as a given type (from above)
readDataType = function(data, index, type)
  -- check mapping
  local mapping = DATA_TYPES[type]
  if mapping == nil then
    print('error: undefined type', type)
    return nil
  end
  -- work out total length
  local type_length = 0
  for m=1,#mapping do
    type_length = type_length + mapping[m][2]
  end
  local type_data = data:sub(index, index+type_length-1)
  -- run through each field of the type
  local result = {}
  local mapping_index = 1
  for m=1,#mapping do
    local field = mapping[m]
    -- if this failed something is wrong, index is off etc
    -- so fail the whole thing
    local ok, err = pcall(readUInt, type_data, mapping_index, field[2])
    if ok then
      result[field[1]] = readUInt(type_data, mapping_index, field[2])
      mapping_index = mapping_index + field[2]
    else 
      return nil
    end
  end
  return result
end

-- reads a data directory entry from the COFF header
-- this is just a DWORD (4 byte + 4 byte) with pointer + size
readDataDirectory = function(name, data, start)
  local data_directory = data:sub(start, start+7)
  local virtual_address = love.data.unpack('<i4', data_directory:sub(1, 4))
  local byte_size = love.data.unpack('<i4', data_directory:sub(5, 8))
  return {
    rva = virtual_address,
    size = byte_size
  }
end

-- reads the data from a given index as a UInt
readUInt = function(data, index, size)
  return love.data.unpack('<i' .. tostring(size), data:sub(index, index + (size-1)))
end

-- reads the root resource directory and all subdirectories
-- this will give a 3 tier structure for various resources
readResourceDirectory = function(data, base, start, tabs, level, table_size)
  if tabs == nil then tabs = '' end
  if start == -1 then return nil end
  if level == nil then level = 1 end

  local rd = readDataType(data, start, 'RESOURCE_DIRECTORY')
  rd.Entries = {}
  if rd == nil then
    return print(tabs .. 'ERR_INCORRECT_RESOURCE_DIRECTORY')
  end
  -- char is reserved to 0, 'sensible' entry limit
  if rd.Characteristics ~= 0 or rd.NumberOfIdEntries+rd.NumberOfNamedEntries > 4096 then
    return print(tabs .. 'ERR_INVALID_RESOURCE_DIRECTORY', rd.Characteristics, rd.NumberOfIdEntries)
  end
  local read_to = rd.NumberOfIdEntries+rd.NumberOfNamedEntries
  local read_from = 1
  for r=read_from,read_to do
    local offset = start + 16 + ((r-1)*8)
    local rde = readDataType(data, offset, 'RESOURCE_DIRECTORY_ENTRY')
    if rde ~= nil then 
      -- if is_id == 0 that means we actually have a string name
      -- the value given is an offset into the resource string table
      local is_string =   bit.rshift(bit.band(rde.Name, 0x80000000), 31)
      local string_offset = bit.band(rde.Name, 0x7FFFFFFF)
      -- if has_dir == 1 then this entry is a subdirectory pointer
      -- as such we should follow the offset set in first_bit to find the next dir
      local has_dir =    bit.rshift(bit.band(rde.DataOffset, 0x80000000), 31)
      local first_bit =   bit.band(rde.DataOffset, 0x7FFFFFFF)
      if has_dir == 1 then
        rde.SubDirectory = readResourceDirectory(data, base, base+first_bit, tabs .. '  ', level+1, table_size)
      else
        local de = readDataType(data, base+first_bit, 'RESOURCE_DATA_ENTRY')
        if de == nil then
          print(tabs .. '    ERR_INVALID_RESOURCE_DATA_ENTRY')
        else
          -- offset of the entry is offset by the table size from the dd 
          local doffset = de.DataOffset - table_size + 1
          local dentry = data:sub(doffset, doffset + de.DataSize-1)
          -- add our actual resource data along with position for modifying later
          rde.DataSize = de.DataSize
          rde.Data = dentry
          rde.Position = doffset
        end
      end
      table.insert(rd.Entries, rde)
    end
  end
  return rd
end

-- modify the given exe file's ICON with the given image file
love.exedit = {}
love.exedit.updateIcon = function(exe_file, image_file)

  print('love.exedit > modiying exe file')

  -- read the data from the file and clone it for later
  local data = love.filesystem.read(exe_file)
  local new_data = data .. ''

  -- if exe file doesnt start with PE it prob has a dos stub
  -- if it does, the position of the PE entry will be at pos 60
  local poffset = 0
  if data:sub(1, 2) ~= 'PE' then
    poffset = readUInt(data, 61, 2)
  end

  -- get the PE data using the PE header
  local pdata = data:sub(poffset+1, #data)
  if pdata:sub(1, 2) ~= 'PE' then
    print('love.exedit > error: invalid PE header')
    return nil
  end
  print('love.exedit > valid PE file', #pdata, pdata:sub(1, 2))

  -- read COFF header, 20 bytes
  local coff_start = 4
  local coff = {
    machine =      readUInt(pdata, coff_start+ 1, 2),
    section_no =   readUInt(pdata, coff_start+ 3, 2),
    timestamp =    readUInt(pdata, coff_start+ 5, 4),
    symbol_table = readUInt(pdata, coff_start+ 9, 4),
    symbol_no =    readUInt(pdata, coff_start+13, 4),
    opt_header =   readUInt(pdata, coff_start+17, 2),
    chars =        readUInt(pdata, coff_start+19, 2)
  }
  if coff.section_no > 96 then
    print('love.exedit > error: invalid section number: ', coff.section_no)
    return nil
  end
  print('love.exedit > coff header', coff.section_no, coff.timestamp, coff.opt_header)

  -- read opt header
  local opt = {
    magic =         readUInt(pdata, coff_start+21, 2),
    majorlversion = readUInt(pdata, coff_start+23, 1),
    minorlversion = readUInt(pdata, coff_start+24, 1),
    codesize =      readUInt(pdata, coff_start+25, 4),
    initdata =      readUInt(pdata, coff_start+29, 4),
    uninitdata =    readUInt(pdata, coff_start+33, 4),
    entrypoint =    readUInt(pdata, coff_start+37, 4),
    codebase =      readUInt(pdata, coff_start+41, 4),
    database =      readUInt(pdata, coff_start+45, 4),
  }
  print('love.exedit > coff opt', opt.magic, opt.majorlversion, opt.minorlversion, opt.initdata)
  if opt.initdata > #pdata then
    print('love.exedit > error: initdata > actual file bytes')
    return nil
  end
  -- 0x10B, 0x20B, 0x107
  -- 0x20B means this is a PE32+ executable with less headers
  local pe32p = false
  if opt.magic ~= 267 and opt.magic ~= 523 and opt.magic ~= 263 then
    print('love.exedit > error: invalid opt header magic', opt.magic)
    return nil
  end
  if opt.magic == 523 then
    pe32p = true
    print('love.exedit > PE32+ detected')
  end

  -- extra coff headers
  -- slight differences depending on pe32p
  local win = {}
  if pe32p == false then
    win = {
      imagebase =         readUInt(pdata, coff_start+ 49, 4),
      sectionalignment =  readUInt(pdata, coff_start+ 53, 4),
      filealignment =     readUInt(pdata, coff_start+ 57, 4),
      majorosversion =    readUInt(pdata, coff_start+ 61, 2),
      minorosversion =    readUInt(pdata, coff_start+ 63, 2),
      majorimageversion = readUInt(pdata, coff_start+ 65, 2),
      minorimageversion = readUInt(pdata, coff_start+ 67, 2),
      majorssversion =    readUInt(pdata, coff_start+ 69, 2),
      minorssversion =    readUInt(pdata, coff_start+ 71, 2),
      win32version =      readUInt(pdata, coff_start+ 73, 4),
      sizeofimage =       readUInt(pdata, coff_start+ 77, 4),
      sizeofheaders =     readUInt(pdata, coff_start+ 81, 4),
      checksum =          readUInt(pdata, coff_start+ 85, 4),
      subsystem =         readUInt(pdata, coff_start+ 89, 2),
      dllchars =          readUInt(pdata, coff_start+ 91, 2),
      stackreserve =      readUInt(pdata, coff_start+ 93, 4),
      stackcommit =       readUInt(pdata, coff_start+ 97, 4),
      heapreserve =       readUInt(pdata, coff_start+101, 4),
      heapcommit =        readUInt(pdata, coff_start+105, 4),
      loaderflags =       readUInt(pdata, coff_start+109, 4),
      rvasizes =          readUInt(pdata, coff_start+113, 4),
    }
  else
    win = {
      imagebase =         readUInt(pdata, coff_start+ 45, 8),
      sectionalignment =  readUInt(pdata, coff_start+ 53, 4),
      filealignment =     readUInt(pdata, coff_start+ 57, 4),
      majorosversion =    readUInt(pdata, coff_start+ 61, 2),
      minorosversion =    readUInt(pdata, coff_start+ 63, 2),
      majorimageversion = readUInt(pdata, coff_start+ 65, 2),
      minorimageversion = readUInt(pdata, coff_start+ 67, 2),
      majorssversion =    readUInt(pdata, coff_start+ 69, 2),
      minorssversion =    readUInt(pdata, coff_start+ 71, 2),
      win32version =      readUInt(pdata, coff_start+ 73, 4),
      sizeofimage =       readUInt(pdata, coff_start+ 77, 4),
      sizeofheaders =     readUInt(pdata, coff_start+ 81, 4),
      checksum =          readUInt(pdata, coff_start+ 85, 4),
      subsystem =         readUInt(pdata, coff_start+ 89, 2),
      dllchars =          readUInt(pdata, coff_start+ 91, 2),
      stackreserve =      readUInt(pdata, coff_start+ 93, 8),
      stackcommit =       readUInt(pdata, coff_start+101, 8),
      heapreserve =       readUInt(pdata, coff_start+109, 8),
      heapcommit =        readUInt(pdata, coff_start+117, 8),
      loaderflags =       readUInt(pdata, coff_start+125, 4),
      rvasizes =          readUInt(pdata, coff_start+129, 4),
    }
  end

  -- sense check some values
  if win.sectionalignment < win.filealignment then
    print('love.exedit > error: invalid section alignment', win.sectionalignment)
    return nil
  end
  if win.filealignment < 512 or win.filealignment > 64000 then
    print('love.exedit > error: invalid file alignment', win.filealignment)
    return nil
  end
  if win.win32version ~= 0 then
    print('love.exedit > error: win32 version is reserved', win.win32version)
    return nil
  end

  -- get number of data dirs in remaining header
  local data_dir_index = 117
  if pe32p then data_dir_index = 133 end
  local resource_table = readDataDirectory('dd_resource_table', pdata, data_dir_index+16)
  local dd_architecture = readUInt(pdata, data_dir_index+57, 8)
  if dd_architecture ~= 0 then
    print('love.exedit > error: data dir architecture is reserved', dd_architecture)
    return nil
  end
  local dd_reserved = readUInt(pdata, data_dir_index+121, 8)
  if dd_reserved ~= 0 then
    print('love.exedit > error: data dir reserved value', dd_reserved)
    return nil
  end

  -- each section has 40 bytes
  local section_table_index = data_dir_index+132
  if section_table_index ~= coff.opt_header + 24 + 1 then
    print('love.exedit > error: section out of alignment', section_table_index, coff.opt_header+24)
    return nil
  end
  local sections = {}
  for s=1,coff.section_no do
    local offset = section_table_index
    local section = {
      name =          pdata:sub(offset, offset+7),
      virtual_size =  readUInt(pdata, offset+ 8, 4),
      virtual_addr =  readUInt(pdata, offset+12, 4),
      raw_size =      readUInt(pdata, offset+16, 4),
      raw_pointer =   readUInt(pdata, offset+20, 4),
      reloc_pointer = readUInt(pdata, offset+24, 4),
      ln_pointer =    readUInt(pdata, offset+28, 4),
      reloc_no =      readUInt(pdata, offset+32, 2),
      ln_no =         readUInt(pdata, offset+34, 2),
      chars =         readUInt(pdata, offset+36, 4),
    }
    section_table_index = section_table_index + 40
    if section.name:sub(1, 1) ~= '.' then
      print('warn: uncommon section name', section.name)
    end
    -- size should be multiple of file alignment
    if section.raw_size % win.filealignment ~= 0 then
      print('love.exedit > error: invalid raw size for section', section.raw_size)
      return nil
    end 
    local section_key = section.name:sub(2, 5)
    sections[section_key] = section
  end

  if sections['rsrc'] == nil then
    print('love.exedit > error: no resource section table found')
    return nil
  end

  -- raw pointer seems to be from start of file rather than start of PE?
  local rsrc_data_index = sections.rsrc.raw_pointer + 1
  local rsrc_data = data:sub(rsrc_data_index, rsrc_data_index+sections.rsrc.raw_size-1)
  local rsrc_offset = sections.rsrc.raw_pointer
  print('love.exedit > resource section', section_table_index, sections.rsrc.raw_pointer, sections.rsrc.raw_size, #rsrc_data, rsrc_offset)

  local ico_icon = love.icon:newIcon(image_file)
  local ico_img = love.graphics.newImage(ico_icon.img)
  local ico_sizes = { 16, 32, 48, 64, 128, 512 }

  -- read top level directory
  -- this will cascade and read all subdirectories
  -- root resource dirs should have 3 levels to them
  local root_dir = readResourceDirectory(rsrc_data, 1, 1, nil, nil, resource_table.size)
  if root_dir == nil then
    print('love.exedit > failed to read resource directory')
    return nil
  end
  --print('ROOT', root_dir.NumberOfIdEntries+root_dir.NumberOfNamedEntries)
  for l1=1,#root_dir.Entries do
    local lvl1_entry = root_dir.Entries[l1]
    local lvl1_type = RESOURCE_TYPES[lvl1_entry.Name]
    --print('  RESOURCE', lvl1_type)
    if lvl1_entry.SubDirectory ~= nil then
      for l2=1,#lvl1_entry.SubDirectory.Entries do
        local lvl2_entry = lvl1_entry.SubDirectory.Entries[l2]
        if lvl2_entry.SubDirectory ~= nil then
          for l3=1,#lvl2_entry.SubDirectory.Entries do
            local lvl3_entry = lvl2_entry.SubDirectory.Entries[l3]
            -- print('    DATA_ENTRY', l2, lvl3_entry.Name, tostring(#lvl3_entry.Data))
            if lvl1_type == 'VERSION' then
              --print('    VERSION_INFO')

              -- @TODO read out version info and then rewrite as needed
              -- https://learn.microsoft.com/en-us/windows/win32/menurc/vs-versioninfo
              local vlength = readUInt(lvl3_entry.Data, 1, 2)
              local vvallen = readUInt(lvl3_entry.Data, 3, 2)
              local vtype = readUInt(lvl3_entry.Data, 4, 2)
              local vkey = lvl3_entry.Data:sub(6, 6+29) -- VS_VERSION_INFO but WCHAR so *2 == 30 bytes
              local vpad = readUInt(lvl3_entry.Data, 36, 2)
              local fixedfileinfo = readDataType(lvl3_entry.Data, 38+vpad, 'FIXED_FILE_INFO')

            end

            -- @TODO if editing the icons properly we'll need to change the GROUP_ICON values
            if lvl1_type == 'GROUP_ICON' then
              local gi_header = readDataType(lvl3_entry.Data, 1, 'GROUP_ICON_HEADER')
              --print('    GROUP_ICON_HEADER', gi_header.Reserved, gi_header.IdType, gi_header.IdCount)
              for gi=1,gi_header.IdCount do
                local offset = 7 + ((gi-1)*14)
                local gi_entry = readDataType(lvl3_entry.Data, offset, 'GROUP_ICON_ENTRY')
                local gi_size = math.abs(gi_entry.Width)
                if gi_size == 0 then gi_size = 256 end -- only stores 0-255, cant have 0 so 256 is 0
                --print('      GROUP_ICON_ENTRY', tostring(gi_size) .. 'px', gi_entry.Id, gi_entry.BytesInRes)
              end
            end

            -- @TODO currently this is very hacky but it does work
            -- the default love icon is quite large compared to PNG data so we can just insert 
            -- our PNG data and pad the rest 

            -- if we want to do this properly, we will not only need to update the GROUP_ICON
            -- but ALL resource headers, and section headers because all positions will change
            -- we'll also need to implement and recalc the checksum from the COFF
            if lvl1_type == 'ICON' then
              local newdata = ico_icon:_resize(ico_img, ico_sizes[l2])
              local padding = lvl3_entry.DataSize - newdata:getSize()
              if padding < 0 then
                newdata = new_data:sub(1, lvl3_entry.DataSize)
                padding = 0
              end
              local prefix = new_data:sub(1, rsrc_data_index+lvl3_entry.Position-2)
              local newimg = newdata:getString() .. string.rep(' ', padding)
              local suffix = new_data:sub(rsrc_data_index+lvl3_entry.Position-2+lvl3_entry.DataSize+1, #new_data)
              new_data = prefix .. newimg .. suffix
            end

          end
        end
      end
    end
  end

  -- return the modified data
  if #data ~= #new_data then
    print('love.exedit > new data doesnt match expected', #data, #new_data)
  end
  print('love.exedit > file modified successfully')
  return new_data

end
