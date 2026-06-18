# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development Commands

### Core Development
```bash
# Run all tests
nim test

# Build the library
nim build

# Run specific test suites
nim tidy          # Test low-level components
nim testDumping   # Test YAML dumping
nim testSerialization # Test object serialization
nim testRefs      # Test references and anchors
nim testQuickstart # Test quickstart examples
nim testJson      # Test JSON compatibility
nim testLex       # Test lexer
nim testParser    # Test parser
nim testErrorMessages # Test error handling
nim testTagLib    # Test tag library
nim testHints     # Test with stricter checks
nim testAll       # Run comprehensive test suite

# Documentation
nim docs          # Generate documentation
nim bench         # Run benchmarks (requires libyaml)
```

### Development Environment
```bash
# Nix development shell (recommended)
nix develop

# Run documentation web server
nix run .#webdocs

# Run tests in Nix environment
nix flake check
```

## Architecture Overview

### Core Design Philosophy
NimYAML is a pure Nim implementation with **zero external dependencies**. It provides a multi-layered API design that supports both high-level convenience and low-level control.

### API Layers (High to Low Level)
1. **High-level API**: `load()` and `dump()` functions for simple serialization
2. **DOM API**: `YamlNode` tree structure for document manipulation
3. **Event Stream API**: `YamlStream` for scalable processing of large documents
4. **Lexer/Parser**: Low-level YAML parsing primitives

### Key Modules and Responsibilities

#### Core Processing Chain
- **`yaml/stream.nim`**: Central `YamlStream` abstraction - all processing flows through this
- **`yaml/parser.nim`**: Converts character stream to YAML events
- **`yaml/private/lex.nim`**: Tokenizes YAML input
- **`yaml/native.nim`**: High-level serialization/construction framework

#### User-Facing APIs  
- **`yaml.nim`**: Main public API module with `load()`, `dump()`, `loadAs()`, `dumpAs()`
- **`yaml/dom.nim`**: Document Object Model for in-memory YAML manipulation
- **`yaml/dumping.nim`**: High-level dumping functions with `Dumper` abstraction

#### Internal Systems
- **`yaml/presenter.nim`**: Event stream to character stream conversion
- **`yaml/private/internal.nim`**: Shared utilities and error types
- **`yaml/taglib.nim`**: YAML tag registration and resolution

### Core Abstractions

#### YamlStream Events
All YAML processing is event-based. Key events:
- `yamlStartDoc`/`yamlEndDoc`: Document boundaries
- `yamlStartSeq`/`yamlEndSeq`: Sequence (array) boundaries  
- `yamlStartMap`/`yamlEndMap`: Mapping (object) boundaries
- `yamlScalar`: Leaf values with content and type tags
- `yamlAlias`: Reference to anchored content

#### Construction vs Representation
- **Construction**: YAML → Nim objects (via `constructChild()` procs)
- **Representation**: Nim objects → YAML (via `representChild()` procs)
- Both systems are extensible for custom types

#### SerializationContext & ConstructionContext
State containers that flow through the serialization pipeline, handling:
- Anchor/alias resolution
- Custom styling preferences  
- Error accumulation and reporting

## Important Configuration

### Version Requirements
- **Nim**: Requires 2.0.0+ (last 1.6.x compatible version was 1.1.0)
- **Dependencies**: None (pure Nim implementation)

### Memory Management
- Compatible with all Nim GC strategies
- ORC recommended for full DOM API support
- Some DOM limitations with ARC (documented in README)

### Build Configuration
The `config.nims` file configures:
- `nimPreviewSlimSystem`: Modern Nim system module
- Warning suppressions for legacy compatibility
- Build tasks and test runners

### Debugging
Use `d:debug` flag to enable internal stack traces for troubleshooting parser issues.

## Testing Strategy

### Test Organization
- Unit tests for individual components in `/test/`
- Official YAML 1.2 specification compliance via `yaml-test-suite/`
- Performance benchmarks comparing against libyaml
- Error message validation for user experience

### Running Specific Tests
Each test suite can be run individually using the task names listed above. The `testAll` task runs the complete test suite including compliance tests.

## Key Architectural Insights

### Stream Processing Design
The library is built around stream processing to handle arbitrarily large YAML documents without loading everything into memory. Even the high-level APIs internally use streaming.

### Tag System
YAML tags are central to type resolution. The library includes:
- Built-in tags for standard types (strings, integers, sequences, etc.)
- Custom tag registration system
- Automatic tag inference for Nim types

### Error Handling Philosophy
Errors preserve context including line/column positions and provide actionable error messages. The construction system accumulates multiple errors when possible rather than failing fast.