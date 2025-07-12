# Contributing to ssbnk

Thank you for your interest in contributing to ssbnk! This document provides guidelines and information for contributors.

## 🎯 Code of Conduct

- Be respectful and inclusive
- Focus on constructive feedback
- Help others learn and grow
- Keep discussions technical and on-topic

## 🚀 Getting Started

### Prerequisites

- Docker and Docker Compose
- Go 1.21+ (for watcher development)
- Basic knowledge of shell scripting
- Familiarity with containerized applications

### Development Setup

1. **Fork the repository**
   ```bash
   git clone https://github.com/yourusername/ssbnk.git
   cd ssbnk
   ```

2. **Set up environment**
   ```bash
   cp .env.example .env
   # Edit .env with your local settings
   ```

3. **Build and run**
   ```bash
   docker compose up --build
   ```

4. **Test the setup**
   ```bash
   ./scripts/detect-display-server.sh
   ```

## 🔧 Development Process

### 1. Create a Feature Branch

```bash
git checkout -b feature/amazing-feature
```

### 2. Make Your Changes

Follow our coding standards (see below) and make your changes.

### 3. Test Your Changes

- Test locally with Docker Compose
- Verify clipboard functionality works
- Check that cleanup processes work correctly
- Test with both X11 and Wayland if possible

### 4. Commit Your Changes

```bash
git add .
git commit -m 'Add amazing feature'
```

Use clear, descriptive commit messages following this format:
- `feat: add new feature`
- `fix: resolve bug in component`
- `docs: update documentation`
- `style: format code`
- `refactor: restructure code`
- `test: add tests`
- `chore: update dependencies`

### 5. Push and Create PR

```bash
git push origin feature/amazing-feature
```

Then create a Pull Request on GitHub.

## 📝 Coding Standards

### Go Code (Watcher Service)

- Follow `gofmt` formatting
- Use `golint` for linting
- Add comments for exported functions
- Handle errors appropriately
- Use meaningful variable names

Example:
```go
// processScreenshot handles the screenshot processing workflow
func processScreenshot(sourcePath string, config Config) error {
    if sourcePath == "" {
        return fmt.Errorf("source path cannot be empty")
    }
    // ... implementation
}
```

### Shell Scripts

- Use `shellcheck` for validation
- Include proper error handling with `set -e`
- Add comments for complex logic
- Use meaningful variable names
- Quote variables to prevent word splitting

Example:
```bash
#!/bin/bash
set -e

# Process screenshot file
process_screenshot() {
    local file="$1"
    
    if [ ! -f "$file" ]; then
        echo "Error: File not found: $file" >&2
        return 1
    fi
    
    # ... implementation
}
```

### Docker

- Use multi-stage builds when appropriate
- Minimize layer count
- Use specific version tags
- Add health checks where applicable
- Follow security best practices

### Documentation

- Update README for any user-facing changes
- Add inline comments for complex code
- Update API documentation for endpoint changes
- Include examples in documentation
- Keep documentation up to date

## 🧪 Testing Requirements

### Manual Testing

All changes should be manually tested:

1. **Basic functionality**
   - Screenshot detection works
   - Files are properly hosted
   - URLs are copied to clipboard
   - Cleanup processes work

2. **Cross-platform testing**
   - Test on X11 systems
   - Test on Wayland systems
   - Verify clipboard functionality

3. **Error scenarios**
   - Test with invalid files
   - Test with permission issues
   - Test with network problems

### Automated Testing

While we don't have extensive automated tests yet, consider adding:
- Unit tests for Go functions
- Integration tests for Docker services
- Shell script tests with bats

## 📋 Pull Request Guidelines

### PR Title

Use a clear, descriptive title:
- ✅ `feat: add support for WebP images`
- ✅ `fix: resolve clipboard issue on Wayland`
- ❌ `update stuff`
- ❌ `fixes`

### PR Description

Include:

1. **What**: What changes were made
2. **Why**: Why the changes were necessary
3. **How**: How the changes work
4. **Testing**: How you tested the changes

Template:
```markdown
## Description
Brief description of changes

## Motivation
Why this change is needed

## Changes
- List of specific changes
- Another change

## Testing
- [ ] Tested on X11
- [ ] Tested on Wayland
- [ ] Tested clipboard functionality
- [ ] Tested cleanup process

## Screenshots
If applicable, add screenshots

## Checklist
- [ ] Code follows style guidelines
- [ ] Self-review completed
- [ ] Documentation updated
- [ ] No breaking changes (or documented)
```

### Review Process

1. **Automated checks** must pass
2. **Manual review** by maintainers
3. **Testing** by reviewers
4. **Approval** required before merge

## 🐛 Bug Reports

### Before Reporting

1. Check existing issues
2. Test with latest version
3. Gather debug information

### Bug Report Template

```markdown
**Environment**
- OS: [e.g., Ubuntu 22.04]
- Docker version: [e.g., 24.0.0]
- Display server: [X11/Wayland]
- ssbnk version: [e.g., v1.0.0]

**Description**
Clear description of the bug

**Steps to Reproduce**
1. Step one
2. Step two
3. Step three

**Expected Behavior**
What should happen

**Actual Behavior**
What actually happens

**Logs**
```
Paste relevant logs here
```

**Screenshots**
If applicable
```

## 💡 Feature Requests

### Feature Request Template

```markdown
**Problem**
Description of the problem you're trying to solve

**Proposed Solution**
How you envision the feature working

**Alternatives**
Other solutions you considered

**Additional Context**
Any other relevant information

**Implementation Ideas**
If you have technical ideas for implementation
```

## 🏷️ Issue Labels

- `bug`: Something isn't working
- `enhancement`: New feature or request
- `documentation`: Improvements to docs
- `good first issue`: Good for newcomers
- `help wanted`: Extra attention needed
- `question`: Further information requested
- `wontfix`: This will not be worked on
- `duplicate`: This issue already exists

## 🎖️ Recognition

Contributors will be recognized in:
- README acknowledgments
- Release notes
- GitHub contributors page

## 📞 Getting Help

- **GitHub Issues**: For bugs and feature requests
- **GitHub Discussions**: For questions and general discussion
- **Documentation**: Check docs/ directory first

## 🔄 Release Process

1. **Version bump** in relevant files
2. **Update CHANGELOG.md**
3. **Create release tag**
4. **Build and test release**
5. **Publish release notes**

## 📚 Resources

- [Docker Best Practices](https://docs.docker.com/develop/dev-best-practices/)
- [Go Code Review Comments](https://github.com/golang/go/wiki/CodeReviewComments)
- [Shell Style Guide](https://google.github.io/styleguide/shellguide.html)
- [Semantic Versioning](https://semver.org/)
- [Keep a Changelog](https://keepachangelog.com/)

Thank you for contributing to ssbnk! 🎉
