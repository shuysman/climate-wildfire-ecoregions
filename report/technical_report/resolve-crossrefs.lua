-- Lua filter to resolve org-mode cross-references into numbered labels
-- Assigns numbers to Figures, Tables, and Sections, then rewrites Links
-- The org source writes "Table [[tab:foo]]" so the link text already has the
-- type word; this filter replaces the link with just the number.
-- Links remain clickable internal hyperlinks in the docx.
-- Captions get "Figure N: " / "Table N: " prepended.

local fig_counter = 0
local tab_counter = 0
local sec_counter = 0

local label_map = {}

-- Helper: prepend "Type N: " to a Caption's block list
local function prepend_caption(caption_blocks, prefix)
  if #caption_blocks > 0 then
    local first = caption_blocks[1]
    if first.t == "Plain" or first.t == "Para" then
      table.insert(first.content, 1, pandoc.Space())
      table.insert(first.content, 1, pandoc.Str(prefix))
    end
  end
end

-- First pass: collect all figure, table, and section labels with numbers
function Pandoc(doc)
  -- Walk blocks to number figures, tables, sections and label captions
  for _, block in ipairs(doc.blocks) do
    if block.t == "Figure" then
      local id = block.identifier
      if id and id ~= "" then
        fig_counter = fig_counter + 1
        label_map[id] = tostring(fig_counter)
        -- Prepend "Figure N." to caption
        if block.caption and block.caption.long then
          prepend_caption(block.caption.long, "Figure " .. fig_counter .. ".")
        end
      end
    elseif block.t == "Table" then
      local id = block.identifier
      if id and id ~= "" then
        tab_counter = tab_counter + 1
        label_map[id] = tostring(tab_counter)
        -- Prepend "Table N." to caption
        if block.caption and block.caption.long then
          prepend_caption(block.caption.long, "Table " .. tab_counter .. ".")
        end
      end
    elseif block.t == "Header" and block.level == 1 then
      sec_counter = sec_counter + 1
      local id = block.identifier
      if id and id ~= "" then
        label_map[id] = tostring(sec_counter)
      end
      -- Check for Span targets inside headers (org <<target>> syntax)
      for _, inline in ipairs(block.content) do
        if inline.t == "Span" and inline.identifier ~= "" then
          label_map[inline.identifier] = tostring(sec_counter)
        end
      end
    elseif block.t == "Header" and block.level == 2 then
      local id = block.identifier
      -- Check for Span targets inside sub-headers
      for _, inline in ipairs(block.content) do
        if inline.t == "Span" and inline.identifier ~= "" then
          label_map[inline.identifier] = tostring(sec_counter)
        end
      end
    end
  end

  -- Second pass: rewrite links as clickable internal hyperlinks
  return doc:walk({
    Link = function(el)
      local target = el.target
      -- Remove leading # if present
      local clean_target = target:gsub("^#", "")

      local label = label_map[clean_target]
      if label then
        return pandoc.Link({pandoc.Str(label)}, "#" .. clean_target)
      end

      -- Also try matching the link content as a key
      if #el.content == 1 and el.content[1].t == "Str" then
        local content_text = el.content[1].text
        label = label_map[content_text]
        if label then
          return pandoc.Link({pandoc.Str(label)}, "#" .. content_text)
        end
      end

      return el
    end
  })
end
