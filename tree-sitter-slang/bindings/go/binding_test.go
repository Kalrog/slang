package tree_sitter_slang_test

import (
	"testing"

	tree_sitter "github.com/tree-sitter/go-tree-sitter"
	tree_sitter_slang "github.com/tree-sitter/tree-sitter-slang/bindings/go"
)

func TestCanLoadGrammar(t *testing.T) {
	language := tree_sitter.NewLanguage(tree_sitter_slang.Language())
	if language == nil {
		t.Errorf("Error loading Slang grammar")
	}
}
